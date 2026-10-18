import Foundation

/// RichDocument → EPUB 3 (with an EPUB 2 NCX for older readers).
enum EPUBWriter {
    static func write(_ doc: RichDocument, to url: URL) throws {
        let title = doc.inferredTitle ?? url.deletingPathExtension().lastPathComponent
        let chapters = split(doc.blocks)
        let identifier = "urn:uuid:\(UUID().uuidString.lowercased())"
        let language = Locale.preferredLanguages.first?.components(separatedBy: "-").first ?? "en"
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)

        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", compress: false)
        zip.add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
        zip.add("OEBPS/style.css", HTMLWriter.stylesheet.replacingOccurrences(of: "max-width: 46em; margin: 2.5em auto; padding: 0 1.25em;", with: "margin: 0; padding: 0;"))

        var manifest: [String] = []
        var spine: [String] = []
        var navItems: [String] = []
        var ncxPoints: [String] = []
        var imageCounter = 0

        for (index, chapter) in chapters.enumerated() {
            let number = String(format: "%03d", index + 1)
            let file = "chapter-\(number).xhtml"
            let chapterTitle = chapter.title ?? (chapters.count == 1 ? title : "Part \(index + 1)")
            var images: [(String, RichImage)] = []
            let body = HTMLWriter.body(chapter.blocks, xhtml: true) { image, _ in
                imageCounter += 1
                let ext = image.fileExtension == "jpeg" ? "jpg" : image.fileExtension
                let name = "images/image-\(imageCounter).\(ext)"
                images.append((name, image))
                return name
            }
            for (name, image) in images {
                zip.add("OEBPS/\(name)", image.data, compress: false)
                manifest.append("<item id=\"\(name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-"))\" href=\"\(name)\" media-type=\"\(image.mimeType)\"/>")
            }
            zip.add("OEBPS/\(file)", """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)">
            <head><meta charset="utf-8"/><title>\(XML.escape(chapterTitle))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
            <body>
            \(body)
            </body>
            </html>
            """)
            manifest.append("<item id=\"c\(number)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>")
            spine.append("<itemref idref=\"c\(number)\"/>")
            navItems.append("<li><a href=\"\(file)\">\(XML.escape(chapterTitle))</a></li>")
            ncxPoints.append("<navPoint id=\"np\(number)\" playOrder=\"\(index + 1)\"><navLabel><text>\(XML.escape(chapterTitle))</text></navLabel><content src=\"\(file)\"/></navPoint>")
        }

        zip.add("OEBPS/nav.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8"/><title>Contents</title></head>
        <body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>\(navItems.joined())</ol></nav></body>
        </html>
        """)
        zip.add("OEBPS/toc.ncx", """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <head><meta name="dtb:uid" content="\(identifier)"/></head>
        <docTitle><text>\(XML.escape(title))</text></docTitle>
        <navMap>\(ncxPoints.joined())</navMap>
        </ncx>
        """)
        zip.add("OEBPS/content.opf", """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(identifier)</dc:identifier>
            <dc:title>\(XML.escape(title))</dc:title>
            <dc:language>\(language)</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
            \(manifest.joined(separator: "\n    "))
          </manifest>
          <spine toc="ncx">
            \(spine.joined(separator: "\n    "))
          </spine>
        </package>
        """)
        try zip.finish().write(to: url)
    }

    private struct Chapter {
        var title: String?
        var blocks: [RichDocument.Block]
    }

    /// Splits at top-level headings so readers get a table of contents.
    private static func split(_ blocks: [RichDocument.Block]) -> [Chapter] {
        let levels = blocks.compactMap { block -> Int? in
            if case .heading(let level, _) = block { return level }
            return nil
        }
        guard let top = levels.min(), levels.filter({ $0 == top }).count >= 2 else {
            return chunk(blocks.filter { if case .pageBreak = $0 { return false }; return true })
        }
        var chapters: [Chapter] = []
        var current = Chapter(title: nil, blocks: [])
        for block in blocks {
            if case .pageBreak = block { continue }
            if case .heading(let level, let spans) = block, level == top {
                if !current.blocks.isEmpty { chapters.append(current) }
                current = Chapter(title: spans.plainText, blocks: [block])
            } else {
                current.blocks.append(block)
            }
        }
        if !current.blocks.isEmpty { chapters.append(current) }
        return chapters
    }

    private static func chunk(_ blocks: [RichDocument.Block]) -> [Chapter] {
        guard blocks.count > 400 else { return [Chapter(title: nil, blocks: blocks)] }
        return stride(from: 0, to: blocks.count, by: 300).map { Chapter(title: nil, blocks: Array(blocks[$0..<min($0 + 300, blocks.count)])) }
    }
}

/// EPUB → RichDocument by walking the spine's XHTML documents.
enum EPUBReader {
    static func read(_ url: URL) throws -> RichDocument {
        let zip = try ZipReader(url: url)
        let container = try XML.document(try zip.read("META-INF/container.xml"))
        guard let opfPath = container.rootElement()?.firstDescendant("rootfile")?.attr("full-path") else {
            throw OrbitError.invalidInput("The EPUB has no package document.")
        }
        let opf = try XML.document(try zip.read(opfPath))
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent
        guard let package = opf.rootElement() else { throw OrbitError.invalidInput("Invalid EPUB package.") }

        var manifest: [String: String] = [:]
        for item in package.child("manifest")?.elementChildren ?? [] {
            if let id = item.attr("id"), let href = item.attr("href") { manifest[id] = href }
        }
        let title = package.child("metadata")?.firstDescendant("title")?.stringValue

        var blocks: [RichDocument.Block] = []
        for itemref in package.child("spine")?.elementChildren ?? [] {
            guard let idref = itemref.attr("idref"), let href = manifest[idref] else { continue }
            let path = resolve(href, relativeTo: opfDirectory)
            guard let data = try? zip.read(path) else { continue }
            let chapterDirectory = (path as NSString).deletingLastPathComponent
            let chapter = try HTMLReader.read(data) { src in
                try? zip.read(resolve(src, relativeTo: chapterDirectory))
            }
            blocks += chapter.blocks
        }
        return RichDocument(title: title, blocks: blocks)
    }

    static func resolve(_ href: String, relativeTo directory: String) -> String {
        let clean = (href.removingPercentEncoding ?? href).components(separatedBy: "#")[0]
        let joined = directory.isEmpty ? clean : directory + "/" + clean
        var parts: [String] = []
        for part in joined.split(separator: "/") {
            if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(String(part)) }
        }
        return parts.joined(separator: "/")
    }
}
