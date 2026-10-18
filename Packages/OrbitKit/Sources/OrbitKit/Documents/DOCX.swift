import Foundation

/// RichDocument → .docx (WordprocessingML) with real heading styles, lists, tables, links and images.
enum DOCXWriter {
    static func write(_ doc: RichDocument, to url: URL) throws {
        try data(for: doc).write(to: url)
    }

    static func data(for doc: RichDocument) throws -> Data {
        var body = ""
        var relationships: [(id: String, type: String, target: String, external: Bool)] = []
        var media: [(name: String, data: Data)] = []
        var orderedListNums: [Int] = []
        var nextNumID = 3
        var previousWasOrderedList = false
        var currentOrderedNum = 2
        var drawingID = 1

        func linkID(_ target: String) -> String {
            if let existing = relationships.first(where: { $0.target == target && $0.external }) { return existing.id }
            let id = "rIdL\(relationships.count + 1)"
            relationships.append((id, "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target, true))
            return id
        }

        func runs(_ spans: [Span], extraProps: String = "") -> String {
            spans.coalesced().map { span in
                var props = extraProps
                if span.bold { props += "<w:b/>" }
                if span.italic { props += "<w:i/>" }
                if span.code { props += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/><w:sz w:val=\"20\"/>" }
                if span.link != nil { props = "<w:rStyle w:val=\"Hyperlink\"/>" + props }
                let rPr = props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
                let pieces = span.text.components(separatedBy: "\n").map { "<w:t xml:space=\"preserve\">\(XML.escape($0))</w:t>" }
                let run = "<w:r>\(rPr)\(pieces.joined(separator: "<w:br/>"))</w:r>"
                if let link = span.link, !link.isEmpty {
                    if link.hasPrefix("#") { return "<w:hyperlink w:anchor=\"\(XML.escape(String(link.dropFirst())))\">\(run)</w:hyperlink>" }
                    return "<w:hyperlink r:id=\"\(linkID(link))\" w:history=\"1\">\(run)</w:hyperlink>"
                }
                return run
            }.joined()
        }

        func paragraph(_ content: String, props: String = "") -> String {
            "<w:p>\(props.isEmpty ? "" : "<w:pPr>\(props)</w:pPr>")\(content)</w:p>"
        }

        for block in doc.blocks {
            if case .listItem(let ordered, _, _) = block, ordered {
                if !previousWasOrderedList {
                    currentOrderedNum = nextNumID
                    orderedListNums.append(nextNumID)
                    nextNumID += 1
                }
                previousWasOrderedList = true
            } else if case .listItem = block {
                // Bullets inside a numbered run keep the numbered list going afterwards.
            } else {
                previousWasOrderedList = false
            }

            switch block {
            case .heading(let level, let spans):
                body += paragraph(runs(spans), props: "<w:pStyle w:val=\"Heading\(max(1, min(level, 6)))\"/>")
            case .paragraph(let spans):
                body += paragraph(runs(spans))
            case .listItem(let ordered, let level, let spans):
                let numID = ordered ? currentOrderedNum : 1
                body += paragraph(runs(spans), props: "<w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(min(level, 8))\"/><w:numId w:val=\"\(numID)\"/></w:numPr>")
            case .code(let code):
                for line in code.components(separatedBy: "\n") {
                    body += paragraph("<w:r><w:t xml:space=\"preserve\">\(XML.escape(line))</w:t></w:r>", props: "<w:pStyle w:val=\"Code\"/>")
                }
            case .quote(let spans):
                body += paragraph(runs(spans), props: "<w:pStyle w:val=\"Quote\"/>")
            case .image(let image):
                let index = media.count + 1
                let ext = image.fileExtension == "jpg" ? "jpeg" : image.fileExtension
                let name = "image\(index).\(ext)"
                media.append((name, image.data))
                let rid = "rIdImg\(index)"
                relationships.append((rid, "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "media/\(name)", false))
                // 96 dpi, capped at 6 inches wide.
                var cx = Double(max(1, image.pixelWidth)) * 9525
                var cy = Double(max(1, image.pixelHeight)) * 9525
                let maxWidth = 6.0 * 914_400
                if cx > maxWidth { cy *= maxWidth / cx; cx = maxWidth }
                let w = Int(cx), h = Int(cy)
                let id = drawingID
                drawingID += 1
                let drawing = """
                <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(w)" cy="\(h)"/><wp:docPr id="\(id)" name="Picture \(id)" descr="\(XML.escape(image.alt ?? ""))"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(id)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(w)" cy="\(h)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
                """
                body += paragraph(drawing)
            case .table(let rows):
                let columns = max(1, rows.map(\.count).max() ?? 1)
                let width = 9000 / columns
                var table = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"0\" w:type=\"auto\"/></w:tblPr><w:tblGrid>"
                table += String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns) + "</w:tblGrid>"
                for (rowIndex, row) in rows.enumerated() {
                    table += "<w:tr>"
                    for column in 0..<columns {
                        let spans = column < row.count ? row[column] : []
                        let content = runs(spans, extraProps: rowIndex == 0 ? "<w:b/>" : "")
                        table += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr>\(paragraph(content))</w:tc>"
                    }
                    table += "</w:tr>"
                }
                body += table + "</w:tbl>" + paragraph("")
            case .rule:
                body += paragraph("", props: "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"auto\"/></w:pBdr>")
            case .pageBreak:
                body += paragraph("<w:r><w:br w:type=\"page\"/></w:r>")
            }
        }
        if body.isEmpty { body = paragraph("") }

        let letter = PageGeometry.prefersLetter
        let section = letter
            ? "<w:pgSz w:w=\"12240\" w:h=\"15840\"/>"
            : "<w:pgSz w:w=\"11906\" w:h=\"16838\"/>"
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)<w:sectPr>\(section)<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
        """

        var rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        <Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
        """
        for rel in relationships {
            rels += "<Relationship Id=\"\(rel.id)\" Type=\"\(rel.type)\" Target=\"\(XML.escape(rel.target))\"\(rel.external ? " TargetMode=\"External\"" : "")/>\n"
        }
        rels += "</Relationships>"

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", rootRels)
        zip.add("docProps/core.xml", coreXML(title: doc.inferredTitle))
        zip.add("word/document.xml", documentXML)
        zip.add("word/_rels/document.xml.rels", rels)
        zip.add("word/styles.xml", stylesXML)
        zip.add("word/numbering.xml", numberingXML(orderedNums: orderedListNums))
        for item in media { zip.add("word/media/\(item.name)", item.data, compress: false) }
        return zip.finish()
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Default Extension="png" ContentType="image/png"/>
    <Default Extension="jpeg" ContentType="image/jpeg"/>
    <Default Extension="jpg" ContentType="image/jpeg"/>
    <Default Extension="gif" ContentType="image/gif"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
    </Types>
    """

    private static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
    </Relationships>
    """

    static func coreXML(title: String?) -> String {
        let date = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(XML.escape(title ?? ""))</dc:title>
        <dc:creator>Orbit</dc:creator>
        <dcterms:created xsi:type="dcterms:W3CDTF">\(date)</dcterms:created>
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(date)</dcterms:modified>
        </cp:coreProperties>
        """
    }

    private static let stylesXML: String = {
        func heading(_ level: Int, _ size: Int, _ color: String) -> String {
            """
            <w:style w:type="paragraph" w:styleId="Heading\(level)"><w:name w:val="heading \(level)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="\(level == 1 ? 360 : 240)" w:after="120"/><w:outlineLvl w:val="\(level - 1)"/></w:pPr><w:rPr><w:b/><w:color w:val="\(color)"/><w:sz w:val="\(size)"/></w:rPr></w:style>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/><w:rPr><w:sz w:val="56"/></w:rPr></w:style>
        \(heading(1, 36, "1F3864"))
        \(heading(2, 30, "2F5496"))
        \(heading(3, 26, "2F5496"))
        \(heading(4, 24, "2F5496"))
        \(heading(5, 22, "2F5496"))
        \(heading(6, 22, "595959"))
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="60"/><w:contextualSpacing/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="720" w:right="720"/></w:pPr><w:rPr><w:i/><w:color w:val="595959"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/></w:pPr><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Menlo"/><w:sz w:val="19"/></w:rPr></w:style>
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:left w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:right w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/></w:tblBorders><w:tblCellMar><w:left w:w="108" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
        </w:styles>
        """
    }()

    private static func numberingXML(orderedNums: [Int]) -> String {
        let bullets = ["•", "◦", "▪"]
        var bulletLevels = ""
        var decimalLevels = ""
        for level in 0..<9 {
            let indent = 720 * (level + 1)
            bulletLevels += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(bullets[level % 3])\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            let format = ["decimal", "lowerLetter", "lowerRoman"][level % 3]
            decimalLevels += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"%\(level + 1).\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }
        var nums = "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num><w:num w:numId=\"2\"><w:abstractNumId w:val=\"1\"/></w:num>"
        for id in orderedNums {
            nums += "<w:num w:numId=\"\(id)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>\(bulletLevels)</w:abstractNum><w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>\(decimalLevels)</w:abstractNum>\(nums)</w:numbering>
        """
    }
}

/// .docx → RichDocument, reading styles, numbering, tables, hyperlinks and embedded images.
enum DOCXReader {
    static func read(_ url: URL) throws -> RichDocument {
        let zip = try ZipReader(url: url)
        let document = try XML.document(try zip.read("word/document.xml"))

        var rels: [String: String] = [:]
        if let relsData = try? zip.read("word/_rels/document.xml.rels"), let relsDoc = try? XML.document(relsData) {
            for rel in relsDoc.rootElement()?.elementChildren ?? [] {
                if let id = rel.attr("Id"), let target = rel.attr("Target") { rels[id] = target }
            }
        }

        // styleId → (heading level?, kind)
        var headingStyles: [String: Int] = [:]
        var quoteStyles = Set<String>()
        var codeStyles = Set<String>()
        if let stylesData = try? zip.read("word/styles.xml"), let styles = try? XML.document(stylesData) {
            for style in styles.rootElement()?.elementChildren.filter({ $0.tag == "style" }) ?? [] {
                guard let id = style.attr("styleId") else { continue }
                let name = (style.child("name")?.attr("val") ?? id).lowercased()
                if let outline = style.child("ppr")?.child("outlinelvl")?.attr("val"), let level = Int(outline), level < 6 {
                    headingStyles[id] = level + 1
                } else if let match = name.firstMatch(of: #/^heading\s*(\d)$/#), let level = Int(match.1) {
                    headingStyles[id] = level
                } else if name == "title" {
                    headingStyles[id] = 1
                } else if name == "subtitle" {
                    headingStyles[id] = 2
                }
                if name.contains("quote") { quoteStyles.insert(id) }
                if name.contains("code") || name.contains("preformatted") || name.contains("source") { codeStyles.insert(id) }
            }
        }

        // numId → ordered?
        var orderedNums: [String: Bool] = [:]
        if let numberingData = try? zip.read("word/numbering.xml"), let numbering = try? XML.document(numberingData),
           let root = numbering.rootElement() {
            var abstractOrdered: [String: Bool] = [:]
            for abstract in root.elementChildren where abstract.tag == "abstractnum" {
                let format = abstract.firstDescendant("numfmt")?.attr("val") ?? "bullet"
                if let id = abstract.attr("abstractNumId") { abstractOrdered[id] = format != "bullet" && format != "none" }
            }
            for num in root.elementChildren where num.tag == "num" {
                if let id = num.attr("numId"), let abstract = num.child("abstractnumid")?.attr("val") {
                    orderedNums[id] = abstractOrdered[abstract] ?? false
                }
            }
        }

        var blocks: [RichDocument.Block] = []
        let context = Context(zip: zip, rels: rels)

        func handle(_ element: XMLElement) {
            switch element.tag {
            case "p":
                let props = element.child("ppr")
                let styleID = props?.child("pstyle")?.attr("val") ?? ""
                let (spans, images, pageBreak) = context.runs(in: element)
                let text = spans.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let numPr = props?.child("numpr"), let numID = numPr.child("numid")?.attr("val"), numID != "0", !text.isEmpty {
                    let level = Int(numPr.child("ilvl")?.attr("val") ?? "0") ?? 0
                    blocks.append(.listItem(ordered: orderedNums[numID] ?? false, level: level, spans: spans.trimmed()))
                } else if let level = headingStyles[styleID], !text.isEmpty {
                    blocks.append(.heading(level: level, spans: spans.trimmed()))
                } else if let outline = props?.child("outlinelvl")?.attr("val"), let level = Int(outline), level < 6, !text.isEmpty {
                    blocks.append(.heading(level: level + 1, spans: spans.trimmed()))
                } else if codeStyles.contains(styleID) {
                    if case .code(let previous)? = blocks.last {
                        blocks[blocks.count - 1] = .code(previous + "\n" + spans.plainText)
                    } else {
                        blocks.append(.code(spans.plainText))
                    }
                } else if quoteStyles.contains(styleID), !text.isEmpty {
                    blocks.append(.quote(spans.trimmed()))
                } else if !text.isEmpty {
                    blocks.append(.paragraph(spans.trimmed()))
                } else if props?.child("pbdr")?.child("bottom") != nil {
                    blocks.append(.rule)
                }
                blocks += images.map { .image($0) }
                if pageBreak { blocks.append(.pageBreak) }
            case "tbl":
                let rows = element.elementChildren.filter { $0.tag == "tr" }.map { row in
                    row.elementChildren.filter { $0.tag == "tc" }.map { cell -> [Span] in
                        var spans: [Span] = []
                        for (index, p) in cell.descendants("p").enumerated() {
                            if index > 0 { spans.append(Span("\n")) }
                            spans += context.runs(in: p).0
                        }
                        return spans.trimmed()
                    }
                }
                if !rows.isEmpty { blocks.append(.table(rows)) }
            case "sdt":
                element.child("sdtcontent")?.elementChildren.forEach(handle)
            default:
                break
            }
        }

        let body = document.rootElement()?.firstDescendant("body")
        body?.elementChildren.forEach(handle)

        var title: String?
        if let core = try? zip.read("docProps/core.xml"), let coreDoc = try? XML.document(core) {
            title = coreDoc.rootElement()?.firstDescendant("title")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return RichDocument(title: title?.isEmpty == false ? title : nil, blocks: blocks)
    }

    private struct Context {
        let zip: ZipReader
        let rels: [String: String]

        /// Returns the paragraph's inline spans, its images, and whether it contains a page break.
        func runs(in paragraph: XMLElement) -> ([Span], [RichImage], Bool) {
            var spans: [Span] = []
            var images: [RichImage] = []
            var pageBreak = false

            func walk(_ element: XMLElement, link: String?) {
                for child in element.elementChildren {
                    switch child.tag {
                    case "r":
                        let props = child.child("rpr")
                        let bold = flag(props?.child("b"))
                        let italic = flag(props?.child("i"))
                        let font = props?.child("rfonts")?.attr("ascii")?.lowercased() ?? ""
                        let code = ["courier", "consolas", "menlo", "monaco", "mono"].contains { font.contains($0) }
                        for item in child.elementChildren {
                            switch item.tag {
                            case "t": spans.append(Span(item.stringValue ?? "", bold: bold, italic: italic, code: code, link: link))
                            case "tab": spans.append(Span("\t", bold: bold, italic: italic, link: link))
                            case "br", "cr":
                                if item.attr("type") == "page" { pageBreak = true } else { spans.append(Span("\n", link: link)) }
                            case "drawing", "pict", "object":
                                let alt = item.firstDescendant("docpr")?.attr("descr")
                                for blip in item.descendants("blip") + item.descendants("imagedata") {
                                    if let id = blip.attr("embed") ?? blip.attr("id"), var image = image(id) {
                                        if let alt, !alt.isEmpty { image.alt = alt }
                                        images.append(image)
                                    }
                                }
                            case "sym":
                                if let hex = item.attr("char"), let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                                    spans.append(Span(String(Character(scalar)), bold: bold, italic: italic, link: link))
                                }
                            default: break
                            }
                        }
                    case "hyperlink":
                        var target = link
                        if let id = child.attr("id"), let resolved = rels[id] { target = resolved }
                        else if let anchor = child.attr("anchor") { target = "#" + anchor }
                        walk(child, link: target)
                    case "ins", "smarttag", "fldsimple", "customxml", "sdt", "sdtcontent":
                        walk(child, link: link)
                    default:
                        break
                    }
                }
            }
            walk(paragraph, link: nil)
            return (spans.coalesced(), images, pageBreak)
        }

        private func flag(_ element: XMLElement?) -> Bool {
            guard let element else { return false }
            let value = element.attr("val")?.lowercased()
            return value == nil || value == "1" || value == "true" || value == "on"
        }

        private func image(_ id: String) -> RichImage? {
            guard let target = rels[id] else { return nil }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "word/" + target
            let normalized = (path as NSString).standardizingPath
            guard let data = try? zip.read(normalized) else { return nil }
            return RichImage.from(data: data)
        }
    }
}

enum PageGeometry {
    /// US-style regions use Letter paper; everyone else gets A4.
    static var prefersLetter: Bool {
        let region: String?
        if #available(macOS 13.0, *) { region = Locale.current.region?.identifier } else { region = Locale.current.regionCode }
        return ["US", "CA", "MX", "PH", "CL", "CO", "VE", "GT", "PR"].contains(region ?? "US")
    }

    static var pageSize: CGSize {
        prefersLetter ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
    }
}
