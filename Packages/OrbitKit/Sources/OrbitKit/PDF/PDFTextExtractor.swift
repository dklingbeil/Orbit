import AppKit
import Foundation
import PDFKit

/// Reconstructs headings, paragraphs and lists from a PDF's text layer (or OCR for scanned pages).
enum PDFTextExtractor {
    private struct Line {
        var text: String
        var spans: [Span]
        var bounds: CGRect
        var fontSize: CGFloat
        var bold: Bool
        var italic: Bool
    }

    static func extract(_ input: URL, password: String?, progress: (Double) -> Void = { _ in }) throws -> RichDocument {
        let document = try PDFSupport.open(input, password: password)
        var pages: [[Line]] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            var lines = textLines(of: page)
            if lines.isEmpty { lines = ocrLines(of: page) }
            pages.append(lines)
            progress(Double(index + 1) / Double(max(1, document.pageCount)))
        }

        // Body size = font size covering the most characters.
        var weights: [CGFloat: Int] = [:]
        for line in pages.joined() { weights[line.fontSize.rounded(), default: 0] += line.text.count }
        let body = weights.max { $0.value < $1.value }?.key ?? 12
        let headingSizes = Array(Set(pages.joined().map { $0.fontSize.rounded() }.filter { $0 >= body * 1.18 })).sorted(by: >)

        var blocks: [RichDocument.Block] = []
        for (pageIndex, lines) in pages.enumerated() {
            if pageIndex > 0, !blocks.isEmpty { blocks.append(.pageBreak) }
            blocks += group(lines, body: body, headingSizes: headingSizes)
        }
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return RichDocument(title: title?.isEmpty == false ? title : nil, blocks: blocks)
    }

    private static func textLines(of page: PDFPage) -> [Line] {
        guard let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        return selection.selectionsByLine().compactMap { lineSelection -> Line? in
            guard let raw = lineSelection.string else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var size: CGFloat = 12
            var bold = false, italic = false
            var spans: [Span] = []
            if let attributed = lineSelection.attributedString, attributed.length > 0 {
                attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                    let piece = (attributed.string as NSString).substring(with: range)
                    guard let font = value as? NSFont else { spans.append(Span(piece)); return }
                    let traits = font.fontDescriptor.symbolicTraits
                    let name = font.fontName.lowercased()
                    spans.append(Span(piece,
                                      bold: traits.contains(.bold) || name.contains("bold") || name.contains("black") || name.contains("heavy"),
                                      italic: traits.contains(.italic) || name.contains("italic") || name.contains("oblique"),
                                      code: traits.contains(.monoSpace) || name.contains("mono") || name.contains("courier") || name.contains("menlo")))
                }
                var sizes: [CGFloat: Int] = [:]
                var boldCount = 0, italicCount = 0
                attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                    guard let font = value as? NSFont else { return }
                    sizes[font.pointSize.rounded(), default: 0] += range.length
                    let traits = font.fontDescriptor.symbolicTraits
                    let name = font.fontName.lowercased()
                    if traits.contains(.bold) || name.contains("bold") || name.contains("black") || name.contains("heavy") { boldCount += range.length }
                    if traits.contains(.italic) || name.contains("italic") || name.contains("oblique") { italicCount += range.length }
                }
                size = sizes.max { $0.value < $1.value }?.key ?? 12
                bold = boldCount * 2 > attributed.length
                italic = italicCount * 2 > attributed.length
            }
            let trimmedSpans = spans.trimmed()
            return Line(text: text, spans: trimmedSpans.isEmpty ? [Span(text)] : trimmedSpans,
                        bounds: lineSelection.bounds(for: page), fontSize: size, bold: bold, italic: italic)
        }
    }

    private static func ocrLines(of page: PDFPage) -> [Line] {
        guard let image = PDFRenderer.render(page, dpi: 200),
              let recognized = try? TextRecognizer.recognize(image) else { return [] }
        let bounds = page.bounds(for: .cropBox)
        return recognized.map { line in
            let rect = CGRect(x: line.box.minX * bounds.width, y: line.box.minY * bounds.height,
                              width: line.box.width * bounds.width, height: line.box.height * bounds.height)
            return Line(text: line.text, spans: [Span(line.text)], bounds: rect, fontSize: (rect.height * 0.8).rounded(), bold: false, italic: false)
        }
    }

    private static let bulletPrefixes: [String] = ["•", "◦", "▪", "‣", "–", "-", "*", "·", "○", "■"]

    /// Detects a list marker; returns whether it's ordered and how many characters it spans.
    private static func listMarker(_ text: String) -> (ordered: Bool, length: Int)? {
        for prefix in bulletPrefixes where text.hasPrefix(prefix + " ") || (text.hasPrefix(prefix) && prefix != "-" && prefix != "*" && text.count > 1 && prefix != "–") {
            let rest = text.dropFirst(prefix.count)
            return (false, prefix.count + rest.prefix(while: \.isWhitespace).count)
        }
        if let match = text.firstMatch(of: #/^(\d{1,3}|[a-zA-Z])[.)]\s+/#) {
            return (true, text.distance(from: text.startIndex, to: match.range.upperBound))
        }
        return nil
    }

    private static func group(_ lines: [Line], body: CGFloat, headingSizes: [CGFloat]) -> [RichDocument.Block] {
        var blocks: [RichDocument.Block] = []
        var paragraph: [Line] = []
        var listItem: (ordered: Bool, lines: [[Span]])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let spans = joinSpans(paragraph.map(\.spans))
            let text = spans.plainText
            let size = paragraph[0].fontSize.rounded()
            let allBold = paragraph.allSatisfy(\.bold)
            let unbolded = spans.map { span -> Span in var s = span; s.bold = false; return s }
            if let level = headingSizes.firstIndex(of: size), text.count < 200 {
                blocks.append(.heading(level: min(level + 1, 6), spans: unbolded.coalesced()))
            } else if allBold && text.count < 120 && paragraph.count <= 2 && !text.hasSuffix(".") && !text.hasSuffix(":") {
                blocks.append(.heading(level: min(headingSizes.count + 1, 6), spans: unbolded.coalesced()))
            } else if spans.allSatisfy(\.code) {
                blocks.append(.code(paragraph.map(\.text).joined(separator: "\n")))
            } else {
                blocks.append(.paragraph(spans))
            }
            paragraph = []
        }
        func flushList() {
            if let item = listItem {
                blocks.append(.listItem(ordered: item.ordered, level: 0, spans: joinSpans(item.lines)))
                listItem = nil
            }
        }

        var previous: Line?
        for line in lines {
            let marker = listMarker(line.text)
            var breaksBefore = false
            if let previous {
                let gap = previous.bounds.minY - line.bounds.maxY
                let lineHeight = max(previous.bounds.height, 1)
                breaksBefore = gap > lineHeight * 0.55
                    || abs(previous.fontSize - line.fontSize) > 1.5
                    || previous.bold != line.bold && (previous.fontSize >= body * 1.18 || line.fontSize >= body * 1.18)
                    || line.bounds.maxY > previous.bounds.maxY + lineHeight * 2 // new column
            }

            if let marker {
                flushParagraph()
                flushList()
                listItem = (marker.ordered, [line.spans.droppingPrefix(marker.length)])
            } else if listItem != nil, !breaksBefore, line.bounds.minX > (previous?.bounds.minX ?? 0) - 2 {
                listItem!.lines.append(line.spans)
            } else {
                flushList()
                if breaksBefore { flushParagraph() }
                paragraph.append(line)
            }
            previous = line
        }
        flushList()
        flushParagraph()
        return blocks
    }

    /// Joins wrapped lines into one span list, healing hyphenation ("exam-" + "ple" → "example").
    static func joinSpans(_ lines: [[Span]]) -> [Span] {
        var result: [Span] = []
        for line in lines where !line.isEmpty {
            if let last = result.last {
                if last.text.hasSuffix("-"), let first = line.first?.text.first, first.isLowercase {
                    result[result.count - 1].text.removeLast()
                } else {
                    let next = line[0]
                    result.append(Span(" ", bold: last.bold && next.bold, italic: last.italic && next.italic, code: last.code && next.code))
                }
            }
            result += line
        }
        return result.coalesced()
    }

    /// Joins wrapped lines, healing hyphenation ("exam-" + "ple" → "example").
    static func joinLines(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            if result.isEmpty { result = line; continue }
            if result.hasSuffix("-"), let first = line.first, first.isLowercase {
                result.removeLast()
                result += line
            } else {
                result += " " + line
            }
        }
        return result
    }
}

/// PDF → XLSX/CSV/ODS/TSV: rebuilds rows and columns from character positions.
enum PDFTableExtractor {
    static func convert(_ input: URL, to target: FileFormat, base: String, context: JobContext) throws -> URL {
        let document = try PDFSupport.open(input, password: context.parameters.password)
        var rows: [[CellValue]] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let pageRows = extractRows(page)
            if !rows.isEmpty, !pageRows.isEmpty { rows.append([]) }
            rows += pageRows.map { $0.map(CellValue.infer) }
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        guard !rows.isEmpty else { throw OrbitError.failed("No text was found in the PDF.") }
        let workbook = Workbook(sheets: [Sheet(name: "Sheet1", rows: rows)])
        let output = context.output(base: base, ext: target.fileExtension)
        try SpreadsheetWriter.write(workbook, as: target, to: output)
        return output
    }

    private struct Glyph {
        let char: Character
        let rect: CGRect
    }

    static func extractRows(_ page: PDFPage) -> [[String]] {
        guard let string = page.string, !string.isEmpty else { return [] }
        var glyphs: [Glyph] = []
        let characters = Array(string)
        var utf16Offset = 0
        for char in characters {
            let length = String(char).utf16.count
            defer { utf16Offset += length }
            if char.isNewline { continue }
            let rect = page.characterBounds(at: utf16Offset)
            if rect.isEmpty && !char.isWhitespace { continue }
            glyphs.append(Glyph(char: char, rect: rect))
        }

        // Cluster glyphs into lines by vertical position.
        var lines: [[Glyph]] = []
        for glyph in glyphs.filter({ !$0.char.isWhitespace }).sorted(by: { $0.rect.midY > $1.rect.midY }) {
            if let lastIndex = lines.indices.last,
               let reference = lines[lastIndex].first,
               abs(reference.rect.midY - glyph.rect.midY) < max(2, reference.rect.height * 0.45) {
                lines[lastIndex].append(glyph)
            } else {
                lines.append([glyph])
            }
        }

        return lines.map { line -> [String] in
            let sorted = line.sorted { $0.rect.minX < $1.rect.minX }
            let widths = sorted.map(\.rect.width).sorted()
            let typical = widths.isEmpty ? 5 : widths[widths.count / 2]
            var cells: [String] = []
            var current = ""
            var lastMaxX: CGFloat?
            for glyph in sorted {
                if let lastMaxX {
                    let gap = glyph.rect.minX - lastMaxX
                    if gap > max(typical * 1.8, 7) {
                        cells.append(current)
                        current = ""
                    } else if gap > typical * 0.25 {
                        current.append(" ")
                    }
                }
                current.append(glyph.char)
                lastMaxX = glyph.rect.maxX
            }
            cells.append(current)
            return cells.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }
}
