import AppKit

/// Converts between NSAttributedString (RTF, RTFD, DOC, ODT, PDF layout) and RichDocument.
enum AttributedBridge {
    // MARK: Reading

    static func read(_ attributed: NSAttributedString) -> RichDocument {
        let string = attributed.string as NSString
        let full = NSRange(location: 0, length: attributed.length)

        var weights: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: full) { value, range, _ in
            if let font = value as? NSFont { weights[font.pointSize.rounded(), default: 0] += range.length }
        }
        let body = weights.max { $0.value < $1.value }?.key ?? 12
        let headingSizes = weights.keys.filter { $0 >= body * 1.15 }.sorted(by: >)

        var blocks: [RichDocument.Block] = []
        var table: (id: ObjectIdentifier, rows: [Int: [Int: [Span]]])?

        func flushTable() {
            guard let current = table else { return }
            let rows = current.rows.keys.sorted().map { row -> [[Span]] in
                let cells = current.rows[row]!
                let maxColumn = cells.keys.max() ?? 0
                return (0...maxColumn).map { cells[$0] ?? [] }
            }
            blocks.append(.table(rows))
            table = nil
        }

        string.enumerateSubstrings(in: full, options: [.byParagraphs]) { substring, range, _, _ in
            let paragraph = substring ?? ""
            let style = range.length > 0
                ? attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                : nil

            if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last {
                let id = ObjectIdentifier(cell.table)
                if table?.id != id { flushTable(); table = (id, [:]) }
                var spans = table!.rows[cell.startingRow]?[cell.startingColumn] ?? []
                if !spans.isEmpty { spans.append(Span("\n")) }
                spans += runs(attributed, range)
                table!.rows[cell.startingRow, default: [:]][cell.startingColumn] = spans.trimmed()
                return
            }
            flushTable()

            // Attachments become image blocks.
            if paragraph.contains("\u{FFFC}") {
                attributed.enumerateAttribute(.attachment, in: range) { value, _, _ in
                    if let attachment = value as? NSTextAttachment, let image = image(from: attachment) {
                        blocks.append(.image(image))
                    }
                }
            }

            var spans = runs(attributed, range).trimmed()
            let text = spans.plainText
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if paragraph.contains("\u{0C}") { blocks.append(.pageBreak) }
                return
            }

            if let lists = style?.textLists, let list = lists.last {
                spans = stripMarker(spans)
                let format = list.markerFormat.rawValue.lowercased()
                let ordered = format.contains("decimal") || format.contains("alpha") || format.contains("roman")
                blocks.append(.listItem(ordered: ordered, level: max(0, lists.count - 1), spans: spans))
                return
            }

            let size = dominantSize(attributed, range)
            if let level = headingSizes.firstIndex(of: size), text.count < 200 {
                blocks.append(.heading(level: min(level + 1, 6), spans: spans.map { var s = $0; s.bold = false; return s }))
            } else if spans.allSatisfy(\.code) {
                if case .code(let previous)? = blocks.last {
                    blocks[blocks.count - 1] = .code(previous + "\n" + text)
                } else {
                    blocks.append(.code(text))
                }
            } else {
                blocks.append(.paragraph(spans))
            }
        }
        flushTable()
        return RichDocument(blocks: blocks)
    }

    private static func runs(_ attributed: NSAttributedString, _ range: NSRange) -> [Span] {
        var spans: [Span] = []
        attributed.enumerateAttributes(in: range) { attributes, subrange, _ in
            var text = (attributed.string as NSString).substring(with: subrange)
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{2028}", with: "\n")
            guard !text.isEmpty else { return }
            var span = Span(text)
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                span.bold = traits.contains(.bold)
                span.italic = traits.contains(.italic)
                span.code = traits.contains(.monoSpace)
            }
            if let link = attributes[.link] {
                span.link = (link as? URL)?.absoluteString ?? (link as? String)
            }
            spans.append(span)
        }
        return spans.coalesced()
    }

    private static func dominantSize(_ attributed: NSAttributedString, _ range: NSRange) -> CGFloat {
        var sizes: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: range) { value, subrange, _ in
            if let font = value as? NSFont { sizes[font.pointSize.rounded(), default: 0] += subrange.length }
        }
        return sizes.max { $0.value < $1.value }?.key ?? 12
    }

    /// Removes list markers such as "\t•\t" or "1." that Cocoa keeps in the text.
    private static func stripMarker(_ spans: [Span]) -> [Span] {
        let text = spans.plainText
        guard let match = text.firstMatch(of: #/^\t?([•◦▪‣\-–*·]|\(?[0-9a-zA-Z]{1,4}[.)])\t?\s*/#) else { return spans }
        var remaining = text.distance(from: text.startIndex, to: match.range.upperBound)
        var result: [Span] = []
        for var span in spans {
            if remaining > 0 {
                let drop = min(remaining, span.text.count)
                span.text = String(span.text.dropFirst(drop))
                remaining -= drop
            }
            if !span.text.isEmpty { result.append(span) }
        }
        return result
    }

    private static func image(from attachment: NSTextAttachment) -> RichImage? {
        if let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents, let image = RichImage.from(data: data) {
            return image
        }
        if let image = attachment.image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let png = PNGEncoder.encode(cg) {
            return RichImage(data: png, fileExtension: "png", pixelWidth: cg.width, pixelHeight: cg.height)
        }
        return nil
    }

    // MARK: Writing

    static func attributedString(_ doc: RichDocument, contentWidth: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont(name: "Helvetica", size: 11.5) ?? .systemFont(ofSize: 11.5)
        let monoFont = NSFont(name: "Menlo", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
        let headingSizes: [CGFloat] = [22, 17, 14.5, 12.5, 11.5, 11.5]
        let textColor = NSColor.black
        var orderedCounters: [Int: Int] = [:]
        var previousWasList = false

        func base(spacing: CGFloat = 7, before: CGFloat = 0) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = spacing
            style.paragraphSpacingBefore = before
            style.lineHeightMultiple = 1.15
            return style
        }

        func font(_ baseFont: NSFont, bold: Bool, italic: Bool) -> NSFont {
            var f = baseFont
            if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
            if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            return f
        }

        func append(_ spans: [Span], baseFont: NSFont, style: NSParagraphStyle, forceBold: Bool = false, color: NSColor = textColor) {
            for span in spans.coalesced() {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: span.code ? monoFont : font(baseFont, bold: span.bold || forceBold, italic: span.italic),
                    .paragraphStyle: style,
                    .foregroundColor: color,
                ]
                if let link = span.link, let url = URL(string: link) {
                    attributes[.link] = url
                    attributes[.foregroundColor] = NSColor(calibratedRed: 0.02, green: 0.35, blue: 0.75, alpha: 1)
                }
                result.append(NSAttributedString(string: span.text.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont, .paragraphStyle: style]))
        }

        for block in doc.blocks {
            var isList = false
            switch block {
            case .heading(let level, let spans):
                let index = max(0, min(level, 6) - 1)
                let size = headingSizes[index]
                append(spans, baseFont: NSFont(name: "Helvetica-Bold", size: size) ?? .boldSystemFont(ofSize: size),
                       style: base(spacing: 6, before: index < 2 ? 14 : 8), forceBold: true)
            case .paragraph(let spans):
                append(spans, baseFont: bodyFont, style: base())
            case .listItem(let ordered, let level, let spans):
                isList = true
                if !previousWasList { orderedCounters = [:] }
                for key in orderedCounters.keys where key > level { orderedCounters[key] = nil }
                let style = base(spacing: 3)
                let indent = CGFloat(level + 1) * 18
                let list = NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)
                style.textLists = [list]
                style.headIndent = indent + 6
                style.firstLineHeadIndent = indent - 12
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 6)]
                let marker: String
                if ordered {
                    orderedCounters[level, default: 0] += 1
                    marker = "\(orderedCounters[level]!)."
                } else {
                    marker = ["•", "◦", "▪"][level % 3]
                }
                append([Span(marker + "\t")] + spans, baseFont: bodyFont, style: style)
            case .code(let code):
                let style = base(spacing: 8)
                style.headIndent = 12
                style.firstLineHeadIndent = 12
                style.lineHeightMultiple = 1.05
                result.append(NSAttributedString(string: code.replacingOccurrences(of: "\n", with: "\u{2028}") + "\n", attributes: [
                    .font: monoFont, .paragraphStyle: style, .foregroundColor: NSColor(white: 0.15, alpha: 1),
                    .backgroundColor: NSColor(white: 0.95, alpha: 1),
                ]))
            case .quote(let spans):
                let style = base()
                style.headIndent = 24
                style.firstLineHeadIndent = 24
                append(spans.map { var s = $0; s.italic = true; return s }, baseFont: bodyFont, style: style, color: NSColor(white: 0.35, alpha: 1))
            case .image(let image):
                guard let nsImage = NSImage(data: image.data) else { continue }
                let attachment = NSTextAttachment()
                attachment.image = nsImage
                var size = CGSize(width: CGFloat(image.pixelWidth) * 0.75, height: CGFloat(image.pixelHeight) * 0.75)
                if size.width > contentWidth { size = CGSize(width: contentWidth, height: size.height * contentWidth / size.width) }
                if size.height > 600 { size = CGSize(width: size.width * 600 / size.height, height: 600) }
                attachment.bounds = CGRect(origin: .zero, size: size)
                let text = NSMutableAttributedString(attachment: attachment)
                text.addAttribute(.paragraphStyle, value: base(spacing: 10), range: NSRange(location: 0, length: text.length))
                result.append(text)
                result.append(NSAttributedString(string: "\n"))
            case .table(let rows):
                let columns = max(1, rows.map(\.count).max() ?? 1)
                let table = NSTextTable()
                table.numberOfColumns = columns
                table.collapsesBorders = true
                table.layoutAlgorithm = .automaticLayoutAlgorithm
                for (rowIndex, row) in rows.enumerated() {
                    for column in 0..<columns {
                        let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                        cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                        cell.setBorderColor(NSColor(white: 0.7, alpha: 1))
                        cell.setWidth(4, type: .absoluteValueType, for: .padding)
                        if rowIndex == 0 { cell.backgroundColor = NSColor(white: 0.94, alpha: 1) }
                        let style = NSMutableParagraphStyle()
                        style.textBlocks = [cell]
                        let spans = column < row.count ? row[column] : []
                        append(spans.isEmpty ? [Span(" ")] : spans, baseFont: NSFont(name: "Helvetica", size: 10) ?? bodyFont,
                               style: style, forceBold: rowIndex == 0)
                    }
                }
                result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
            case .rule:
                let style = base(spacing: 12, before: 6)
                let line = NSTextBlock()
                line.setWidth(0.75, type: .absoluteValueType, for: .border, edge: .maxY)
                line.setBorderColor(NSColor(white: 0.75, alpha: 1), for: .maxY)
                style.textBlocks = [line]
                style.lineHeightMultiple = 0.3
                result.append(NSAttributedString(string: "\u{00A0}\n", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: style]))
            case .pageBreak:
                result.append(NSAttributedString(string: "\u{0C}", attributes: [.font: bodyFont]))
            }
            previousWasList = isList
        }
        return result
    }
}

/// Lays out an attributed string across pages and writes a PDF.
enum PDFPaginator {
    static func write(_ attributed: NSAttributedString, to url: URL, pageSize: CGSize = PageGeometry.pageSize, margin: CGFloat = 64) throws {
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let contentSize = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)

        var containers: [NSTextContainer] = []
        while true {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
            let range = layoutManager.glyphRange(for: container)
            if range.upperBound >= layoutManager.numberOfGlyphs || containers.count > 5000 { break }
            if range.length == 0 && containers.count > 1 {
                // A single element taller than a page; stop rather than looping forever.
                break
            }
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw OrbitError.failed("Couldn't create \(url.lastPathComponent).")
        }
        let previous = NSGraphicsContext.current
        for container in containers {
            let range = layoutManager.glyphRange(for: container)
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let origin = CGPoint(x: margin, y: margin)
            layoutManager.drawBackground(forGlyphRange: range, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: range, at: origin)
            context.restoreGState()
            context.endPDFPage()
        }
        NSGraphicsContext.current = previous
        context.closePDF()
    }
}
