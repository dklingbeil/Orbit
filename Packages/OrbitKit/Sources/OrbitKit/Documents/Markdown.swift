import Foundation

/// CommonMark-ish Markdown reader: headings, paragraphs, lists, code, quotes, tables, rules, images.
enum MarkdownReader {
    static func read(_ source: String, baseURL: URL?) -> RichDocument {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [RichDocument.Block] = []
        var paragraph: [String] = []
        var index = 0
        var lastListItem: Int?   // index into blocks of the list item continuation lines attach to

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            blocks.append(.paragraph(inline(softBreaks(text))))
            paragraph = []
        }

        // Skip YAML front matter.
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            index = end + 1
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }

            if trimmed.isEmpty {
                flushParagraph()
                lastListItem = nil
                continue
            }

            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                lastListItem = nil
                continue
            }

            // ATX heading
            if let match = trimmed.firstMatch(of: #/^(#{1,6})\s+(.*?)\s*#*\s*$/#) {
                flushParagraph()
                blocks.append(.heading(level: match.1.count, spans: inline(String(match.2))))
                lastListItem = nil
                continue
            }

            // Setext heading
            if !paragraph.isEmpty, trimmed.allSatisfy({ $0 == "=" }) || (trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 2) {
                let text = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                paragraph = []
                blocks.append(.heading(level: trimmed.first == "=" ? 1 : 2, spans: inline(text)))
                continue
            }

            // Horizontal rule
            if paragraph.isEmpty, trimmed.firstMatch(of: #/^([-*_])(\s*\1){2,}$/#) != nil {
                blocks.append(.rule)
                lastListItem = nil
                continue
            }

            // Block quote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let t = lines[index].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                index -= 1
                blocks.append(.quote(inline(softBreaks(quoted.joined(separator: "\n")))))
                lastListItem = nil
                continue
            }

            // List item
            if let match = line.firstMatch(of: #/^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/#) {
                flushParagraph()
                let indent = match.1.replacingOccurrences(of: "\t", with: "    ").count
                let ordered = match.2.first?.isNumber == true
                var text = String(match.3)
                // Task list checkboxes
                if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) }
                if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { text = "☑ " + text.dropFirst(4) }
                blocks.append(.listItem(ordered: ordered, level: min(indent / 2, 8), spans: inline(text)))
                lastListItem = blocks.count - 1
                continue
            }
            if let itemIndex = lastListItem, line.hasPrefix("  ") || line.hasPrefix("\t"),
               case .listItem(let ordered, let level, let spans) = blocks[itemIndex] {
                blocks[itemIndex] = .listItem(ordered: ordered, level: level, spans: spans + [Span(" ")] + inline(trimmed))
                continue
            }

            // Table
            if trimmed.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                var rows: [[[Span]]] = [tableCells(trimmed).map(inline)]
                index += 2
                while index < lines.count {
                    let t = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.contains("|") else { break }
                    rows.append(tableCells(t).map(inline))
                    index += 1
                }
                index -= 1
                blocks.append(.table(rows))
                lastListItem = nil
                continue
            }

            // Standalone image
            if paragraph.isEmpty, let match = trimmed.firstMatch(of: #/^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)$/#) {
                if let image = loadImage(String(match.2), alt: String(match.1), baseURL: baseURL) {
                    blocks.append(.image(image))
                } else {
                    blocks.append(.paragraph([Span(String(match.1).isEmpty ? String(match.2) : String(match.1), link: String(match.2))]))
                }
                continue
            }

            // Indented code
            if paragraph.isEmpty, line.hasPrefix("    ") || line.hasPrefix("\t") {
                var code: [String] = []
                while index < lines.count, lines[index].hasPrefix("    ") || lines[index].hasPrefix("\t") || lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let l = lines[index]
                    code.append(l.hasPrefix("\t") ? String(l.dropFirst()) : String(l.dropFirst(min(4, l.count))))
                    index += 1
                }
                index -= 1
                while code.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeLast() }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            lastListItem = nil
            paragraph.append(line)
        }
        flushParagraph()
        return RichDocument(blocks: blocks)
    }

    /// Two trailing spaces (or a backslash) mark a hard break; other newlines are soft.
    private static func softBreaks(_ text: String) -> String {
        text.components(separatedBy: "\n").enumerated().map { _, line in line }.reduce(into: "") { result, line in
            if result.isEmpty { result = line; return }
            if result.hasSuffix("  ") || result.hasSuffix("\\") {
                result = String(result.trimmingCharacters(in: CharacterSet(charactersIn: " \\")))
                result += "\n" + line
            } else {
                result += " " + line
            }
        }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        return t.allSatisfy { "|:- ".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for char in t {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(char)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func loadImage(_ path: String, alt: String, baseURL: URL?) -> RichImage? {
        if path.hasPrefix("data:"), let data = dataURI(path) { return RichImage.from(data: data, alt: alt) }
        guard !path.hasPrefix("http://"), !path.hasPrefix("https://") else { return nil }
        let decoded = path.removingPercentEncoding ?? path
        let url = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : (baseURL ?? URL(fileURLWithPath: "/")).appendingPathComponent(decoded)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return RichImage.from(data: data, alt: alt)
    }

    static func dataURI(_ uri: String) -> Data? {
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[..<comma]
        let payload = String(uri[uri.index(after: comma)...])
        if header.contains(";base64") { return Data(base64Encoded: payload, options: .ignoreUnknownCharacters) }
        return payload.removingPercentEncoding.map { Data($0.utf8) }
    }

    // MARK: Inline

    static func inline(_ text: String) -> [Span] {
        inline(Array(text), bold: false, italic: false, link: nil).coalesced()
    }

    private static func inline(_ chars: [Character], bold: Bool, italic: Bool, link: String?) -> [Span] {
        var spans: [Span] = []
        var buffer = ""
        var i = 0
        func flush() {
            if !buffer.isEmpty { spans.append(Span(buffer, bold: bold, italic: italic, link: link)); buffer = "" }
        }

        while i < chars.count {
            let c = chars[i]

            if c == "\\", i + 1 < chars.count, "\\`*_{}[]()#+-.!|~<>".contains(chars[i + 1]) {
                buffer.append(chars[i + 1]); i += 2; continue
            }

            if c == "`" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                if let close = find(chars, String(repeating: "`", count: run), from: i + run) {
                    flush()
                    let code = String(chars[(i + run)..<close]).trimmingCharacters(in: .whitespaces)
                    spans.append(Span(code, bold: bold, italic: italic, code: true, link: link))
                    i = close + run
                    continue
                }
                buffer += String(repeating: "`", count: run); i += run; continue
            }

            if c == "!", i + 1 < chars.count, chars[i + 1] == "[", let parsed = parseLink(chars, at: i + 1) {
                flush()
                if !parsed.label.isEmpty { spans.append(Span(parsed.label, bold: bold, italic: italic, link: parsed.url)) }
                i = parsed.end
                continue
            }

            if c == "[", let parsed = parseLink(chars, at: i) {
                flush()
                spans += inline(Array(parsed.label), bold: bold, italic: italic, link: parsed.url)
                i = parsed.end
                continue
            }

            if c == "<", let close = chars[i...].firstIndex(of: ">") {
                let inner = String(chars[(i + 1)..<close])
                if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") {
                    flush()
                    spans.append(Span(inner.replacingOccurrences(of: "mailto:", with: ""), bold: bold, italic: italic, link: inner))
                    i = close + 1
                    continue
                }
            }

            if c == "~", i + 1 < chars.count, chars[i + 1] == "~", let close = find(chars, "~~", from: i + 2) {
                flush()
                spans += inline(Array(chars[(i + 2)..<close]), bold: bold, italic: italic, link: link)
                i = close + 2
                continue
            }

            if c == "*" || c == "_" {
                var run = 0
                while i + run < chars.count, chars[i + run] == c { run += 1 }
                let leftIsWord = i > 0 && (chars[i - 1].isLetter || chars[i - 1].isNumber)
                let nextIsSpace = i + run >= chars.count || chars[i + run].isWhitespace
                if (c == "_" && leftIsWord) || nextIsSpace {
                    buffer += String(repeating: c, count: run); i += run; continue
                }
                let width = min(run, 3)
                let delimiter = String(repeating: c, count: width)
                if let close = findClosing(chars, delimiter, from: i + width) {
                    flush()
                    let inner = Array(chars[(i + width)..<close])
                    spans += inline(inner, bold: bold || width >= 2, italic: italic || width != 2, link: link)
                    i = close + width
                    continue
                }
                buffer += String(repeating: c, count: run); i += run; continue
            }

            buffer.append(c)
            i += 1
        }
        flush()
        return spans
    }

    private static func find(_ chars: [Character], _ needle: String, from start: Int) -> Int? {
        let n = Array(needle)
        guard !n.isEmpty, start <= chars.count - n.count else { return nil }
        var i = start
        while i <= chars.count - n.count {
            if Array(chars[i..<(i + n.count)]) == n { return i }
            i += 1
        }
        return nil
    }

    private static func findClosing(_ chars: [Character], _ delimiter: String, from start: Int) -> Int? {
        let d = Array(delimiter)
        var i = start
        while i <= chars.count - d.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "`", let close = find(chars, "`", from: i + 1) { i = close + 1; continue }
            if Array(chars[i..<(i + d.count)]) == d, i > start, !chars[i - 1].isWhitespace {
                // Don't stop inside a longer run (e.g. "**" when looking for "*").
                let after = i + d.count
                if after < chars.count, chars[after] == d[0], d.count < 3 {
                    i = after + 1
                    while i < chars.count, chars[i] == d[0] { i += 1 }
                    continue
                }
                if d[0] == "_", after < chars.count, chars[after].isLetter || chars[after].isNumber { i += 1; continue }
                return i
            }
            i += 1
        }
        return nil
    }

    private static func parseLink(_ chars: [Character], at start: Int) -> (label: String, url: String, end: Int)? {
        guard chars[start] == "[" else { return nil }
        var depth = 0
        var i = start
        var labelEnd: Int?
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "[" { depth += 1 }
            if chars[i] == "]" {
                depth -= 1
                if depth == 0 { labelEnd = i; break }
            }
            i += 1
        }
        guard let labelEnd, labelEnd + 1 < chars.count, chars[labelEnd + 1] == "(" else { return nil }
        var j = labelEnd + 2
        var parens = 1
        while j < chars.count {
            if chars[j] == "(" { parens += 1 }
            if chars[j] == ")" { parens -= 1; if parens == 0 { break } }
            j += 1
        }
        guard j < chars.count else { return nil }
        var target = String(chars[(labelEnd + 2)..<j]).trimmingCharacters(in: .whitespaces)
        if let space = target.firstIndex(of: " ") { target = String(target[..<space]) }
        if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
        return (String(chars[(start + 1)..<labelEnd]), target, j + 1)
    }
}

/// RichDocument → Markdown.
enum MarkdownWriter {
    static func write(_ document: RichDocument) -> String {
        var parts: [String] = []
        var previousWasList = false
        var previousTopLevelOrdered: Bool?
        var counters: [Int: Int] = [:]
        for block in document.blocks {
            var startsNewList = false
            var text: String
            var isList = false
            switch block {
            case .heading(let level, let spans):
                text = String(repeating: "#", count: max(1, min(level, 6))) + " " + inline(spans)
            case .paragraph(let spans):
                text = inline(spans)
                if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            case .listItem(let ordered, let level, let spans):
                isList = true
                if level == 0 {
                    if let previous = previousTopLevelOrdered, previous != ordered, previousWasList { startsNewList = true; counters = [:] }
                    previousTopLevelOrdered = ordered
                }
                if !previousWasList { counters = [:] }
                for key in counters.keys where key > level { counters[key] = nil }
                let marker: String
                if ordered {
                    counters[level, default: 0] += 1
                    marker = "\(counters[level]!)."
                } else {
                    marker = "-"
                }
                text = String(repeating: "   ", count: level) + marker + " " + inline(spans)
            case .code(let code):
                let fence = code.contains("```") ? "~~~" : "```"
                text = "\(fence)\n\(code)\n\(fence)"
            case .quote(let spans):
                text = inline(spans).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            case .image(let image):
                guard let alt = image.alt, !alt.isEmpty else { continue }
                text = "*[Image: \(alt)]*"
            case .table(let rows):
                guard let header = rows.first else { continue }
                let columns = rows.map(\.count).max() ?? header.count
                func row(_ cells: [[Span]]) -> String {
                    let padded = cells + Array(repeating: [], count: max(0, columns - cells.count))
                    return "| " + padded.map { inline($0).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
                        .joined(separator: " | ") + " |"
                }
                let plainHeader = header.map { $0.map { span -> Span in var s = span; s.bold = false; return s } }
                text = ([row(plainHeader), "|" + Array(repeating: " --- |", count: columns).joined()] + rows.dropFirst().map(row)).joined(separator: "\n")
            case .rule:
                text = "---"
            case .pageBreak:
                continue
            }
            if !isList { previousTopLevelOrdered = nil }
            if isList && previousWasList && !startsNewList, let last = parts.popLast() {
                parts.append(last + "\n" + text)
            } else {
                parts.append(text)
            }
            previousWasList = isList
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    static func inline(_ spans: [Span]) -> String {
        spans.coalesced().map { span -> String in
            if span.code {
                let ticks = span.text.contains("`") ? "``" : "`"
                return wrapLink(ticks + span.text + ticks, span.link)
            }
            let escaped = escape(span.text)
            let leading = String(escaped.prefix(while: \.isWhitespace))
            let trailing = String(escaped.reversed().prefix(while: \.isWhitespace).reversed())
            var core = escaped.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return escaped }
            if span.bold && span.italic { core = "***\(core)***" } else if span.bold { core = "**\(core)**" } else if span.italic { core = "*\(core)*" }
            core = core.replacingOccurrences(of: "\n", with: "  \n")
            return leading + wrapLink(core, span.link) + trailing
        }.joined()
    }

    private static func wrapLink(_ text: String, _ link: String?) -> String {
        guard let link, !link.isEmpty else { return text }
        return "[\(text)](\(link.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: ")", with: "%29")))"
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            switch c {
            case "\\", "`", "*":
                out.append("\\"); out.append(c)
            case "_":
                let prevWord = i > 0 && (chars[i - 1].isLetter || chars[i - 1].isNumber)
                let nextWord = i + 1 < chars.count && (chars[i + 1].isLetter || chars[i + 1].isNumber)
                if !(prevWord && nextWord) { out.append("\\") }
                out.append(c)
            case "#" where out.isEmpty || out.hasSuffix("\n"):
                out.append("\\#")
            default:
                out.append(c)
            }
        }
        return out
    }
}
