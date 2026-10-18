import Foundation

/// RichDocument → HTML / XHTML.
enum HTMLWriter {
    static let stylesheet = """
    body { font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif; color: #1d1d1f; max-width: 46em; margin: 2.5em auto; padding: 0 1.25em; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.6em 0 0.6em; }
    h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
    p, ul, ol, pre, blockquote, table { margin: 0 0 1em; }
    img { max-width: 100%; height: auto; }
    pre { background: #f5f5f7; padding: 0.8em 1em; border-radius: 6px; overflow-x: auto; }
    code { font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 0.9em; }
    blockquote { border-left: 3px solid #d2d2d7; margin-left: 0; padding-left: 1em; color: #555; }
    table { border-collapse: collapse; }
    th, td { border: 1px solid #d2d2d7; padding: 0.35em 0.7em; text-align: left; vertical-align: top; }
    th { background: #f5f5f7; }
    hr { border: none; border-top: 1px solid #d2d2d7; margin: 2em 0; }
    .page-break { page-break-after: always; break-after: page; }
    @media (prefers-color-scheme: dark) {
      body { background: #1d1d1f; color: #f5f5f7; }
      pre, th { background: #2c2c2e; }
      th, td, hr { border-color: #48484a; }
      blockquote { color: #aaa; border-color: #48484a; }
      a { color: #4da3ff; }
    }
    """

    /// A standalone HTML page with images embedded as data URIs.
    static func document(_ doc: RichDocument) -> String {
        let title = escape(doc.inferredTitle ?? "Document")
        let body = self.body(doc.blocks) { image, _ in "data:\(image.mimeType);base64,\(image.data.base64EncodedString())" }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>

        """
    }

    /// Body markup. `imageSource` maps each image (and its running index) to a `src`.
    static func body(_ blocks: [RichDocument.Block], xhtml: Bool = false, imageSource: (RichImage, Int) -> String) -> String {
        var html: [String] = []
        var listStack: [Bool] = []      // ordered flags of open lists
        var itemOpen: [Bool] = []       // whether each open list has an open <li>
        var imageIndex = 0
        let br = xhtml ? "<br/>" : "<br>"

        func closeLists(to depth: Int) {
            while listStack.count > depth {
                if itemOpen.last == true { html.append("</li>") }
                html.append(listStack.removeLast() ? "</ol>" : "</ul>")
                itemOpen.removeLast()
            }
        }

        for block in blocks {
            if case .listItem(let ordered, let rawLevel, let spans) = block {
                let level = min(rawLevel, listStack.count)
                closeLists(to: level + 1)
                if listStack.count == level + 1 {
                    if itemOpen[level] { html.append("</li>"); itemOpen[level] = false }
                    if listStack[level] != ordered {
                        closeLists(to: level)
                    }
                }
                while listStack.count < level + 1 {
                    if let last = itemOpen.indices.last, !itemOpen[last] { html.append("<li>"); itemOpen[last] = true }
                    html.append(ordered ? "<ol>" : "<ul>")
                    listStack.append(ordered)
                    itemOpen.append(false)
                }
                html.append("<li>" + inline(spans, br: br))
                itemOpen[itemOpen.count - 1] = true
                continue
            }
            closeLists(to: 0)

            switch block {
            case .heading(let level, let spans):
                let l = max(1, min(level, 6))
                html.append("<h\(l)>\(inline(spans, br: br))</h\(l)>")
            case .paragraph(let spans):
                let content = inline(spans, br: br)
                if !content.trimmingCharacters(in: .whitespaces).isEmpty { html.append("<p>\(content)</p>") }
            case .code(let code):
                html.append("<pre><code>\(escape(code))</code></pre>")
            case .quote(let spans):
                html.append("<blockquote><p>\(inline(spans, br: br))</p></blockquote>")
            case .image(let image):
                imageIndex += 1
                let alt = escape(image.alt ?? "")
                html.append(xhtml ? "<p><img src=\"\(imageSource(image, imageIndex))\" alt=\"\(alt)\"/></p>"
                                  : "<p><img src=\"\(imageSource(image, imageIndex))\" alt=\"\(alt)\"></p>")
            case .table(let rows):
                guard let header = rows.first else { continue }
                var table = "<table>\n<thead><tr>" + header.map { "<th>\(inline($0, br: br))</th>" }.joined() + "</tr></thead>\n<tbody>\n"
                for row in rows.dropFirst() {
                    table += "<tr>" + row.map { "<td>\(inline($0, br: br))</td>" }.joined() + "</tr>\n"
                }
                html.append(table + "</tbody>\n</table>")
            case .rule:
                html.append(xhtml ? "<hr/>" : "<hr>")
            case .pageBreak:
                html.append("<div class=\"page-break\"></div>")
            case .listItem:
                break
            }
        }
        closeLists(to: 0)
        return html.joined(separator: "\n")
    }

    static func inline(_ spans: [Span], br: String = "<br>") -> String {
        spans.coalesced().map { span in
            var text = escape(span.text).replacingOccurrences(of: "\n", with: br)
            if span.code { text = "<code>\(text)</code>" }
            if span.italic { text = "<em>\(text)</em>" }
            if span.bold { text = "<strong>\(text)</strong>" }
            if let link = span.link { text = "<a href=\"\(escape(link))\">\(text)</a>" }
            return text
        }.joined()
    }

    static func escape(_ s: String) -> String {
        XML.escape(s).replacingOccurrences(of: "&apos;", with: "&#39;")
    }
}

/// HTML / XHTML → RichDocument, via Foundation's XMLDocument (with HTML tidying for tag soup).
enum HTMLReader {
    static func read(_ data: Data, loadResource: @escaping (String) -> Data? = { _ in nil }) throws -> RichDocument {
        let document: XMLDocument
        if let strict = try? XMLDocument(data: data, options: []) {
            document = strict
        } else {
            document = try XML.document(data, tidyHTML: true)
        }
        guard let root = document.rootElement() else { return RichDocument() }
        let title = root.firstDescendant("title")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = root.firstDescendant("body") ?? root
        var builder = Builder(loadResource: loadResource)
        builder.blocks(of: body, listLevel: 0)
        builder.flush()
        return RichDocument(title: title?.isEmpty == false ? title : nil, blocks: builder.output)
    }

    private struct Builder {
        let loadResource: (String) -> Data?
        var output: [RichDocument.Block] = []
        var pending: [Span] = []

        init(loadResource: @escaping (String) -> Data?) {
            self.loadResource = loadResource
        }

        mutating func flush() {
            let spans = pending.trimmed()
            if !spans.isEmpty { output.append(.paragraph(spans)) }
            pending = []
        }

        static let skip: Set<String> = ["head", "script", "style", "noscript", "template", "svg", "math", "nav"]
        static let blockTags: Set<String> = ["p", "div", "section", "article", "main", "header", "footer", "aside", "figure", "figcaption",
                                             "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "pre", "blockquote", "table", "hr",
                                             "dl", "dt", "dd", "body", "center", "address", "details", "summary", "form", "fieldset"]

        mutating func blocks(of element: XMLElement, listLevel: Int) {
            for node in element.children ?? [] {
                guard let child = node as? XMLElement else {
                    if node.kind == .text, let text = node.stringValue { pending += [Span(collapse(text))] }
                    continue
                }
                let tag = child.tag
                if Self.skip.contains(tag) { continue }
                if !Self.blockTags.contains(tag) && tag != "img" && tag != "br" {
                    pending += inline(child)
                    continue
                }
                switch tag {
                case "br":
                    pending.append(Span("\n"))
                case "img":
                    flush()
                    if let image = image(child) { output.append(.image(image)) }
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    flush()
                    let spans = inline(child).trimmed()
                    if !spans.isEmpty { output.append(.heading(level: Int(String(tag.last!)) ?? 1, spans: spans)) }
                case "p", "dt", "dd", "figcaption", "summary", "address":
                    flush()
                    let images = child.descendants("img")
                    pending = inline(child)
                    flush()
                    for img in images { if let image = image(img) { output.append(.image(image)) } }
                case "ul", "ol":
                    flush()
                    list(child, ordered: tag == "ol", level: listLevel)
                case "pre":
                    flush()
                    output.append(.code((child.stringValue ?? "").trimmingCharacters(in: .newlines)))
                case "blockquote":
                    flush()
                    let spans = inline(child).trimmed()
                    if !spans.isEmpty { output.append(.quote(spans)) }
                case "table":
                    flush()
                    let rows = child.descendants("tr").map { row in
                        row.elementChildren.filter { $0.tag == "td" || $0.tag == "th" }.map { inline($0).trimmed() }
                    }.filter { !$0.isEmpty }
                    if !rows.isEmpty { output.append(.table(rows)) }
                case "hr":
                    flush()
                    output.append(.rule)
                default:
                    flush()
                    if (child.attr("style") ?? "").contains("page-break") || (child.attr("class") ?? "").contains("page-break") {
                        output.append(.pageBreak)
                    }
                    blocks(of: child, listLevel: listLevel)
                    flush()
                }
            }
        }

        mutating func list(_ element: XMLElement, ordered: Bool, level: Int) {
            for item in element.elementChildren where item.tag == "li" {
                var spans: [Span] = []
                var nested: [XMLElement] = []
                for node in item.children ?? [] {
                    if let child = node as? XMLElement, child.tag == "ul" || child.tag == "ol" {
                        nested.append(child)
                    } else if let child = node as? XMLElement {
                        if child.tag == "p" || child.tag == "div" { spans += [Span(" ")] }
                        spans += inline(child)
                    } else if let text = node.stringValue {
                        spans.append(Span(collapse(text)))
                    }
                }
                output.append(.listItem(ordered: ordered, level: level, spans: spans.trimmed()))
                for child in nested { list(child, ordered: child.tag == "ol", level: level + 1) }
            }
        }

        func image(_ element: XMLElement) -> RichImage? {
            guard let src = element.attr("src") else { return nil }
            let data: Data?
            if src.hasPrefix("data:") { data = MarkdownReader.dataURI(src) } else { data = loadResource(src) }
            return data.flatMap { RichImage.from(data: $0, alt: element.attr("alt")) }
        }

        func inline(_ node: XMLNode, bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil) -> [Span] {
            if node.kind == .text { return [Span(collapse(node.stringValue ?? ""), bold: bold, italic: italic, code: code, link: link)] }
            guard let element = node as? XMLElement else { return [] }
            var b = bold, i = italic, c = code, l = link
            switch element.tag {
            case "strong", "b": b = true
            case "em", "i", "cite", "var": i = true
            case "code", "kbd", "samp", "tt": c = true
            case "a": l = element.attr("href") ?? link
            case "br": return [Span("\n")]
            case "img", "script", "style": return []
            case "span":
                let style = (element.attr("style") ?? "").lowercased()
                if style.contains("bold") || style.contains("font-weight:7") || style.contains("font-weight: 7") { b = true }
                if style.contains("italic") { i = true }
            default: break
            }
            return (element.children ?? []).flatMap { inline($0, bold: b, italic: i, code: c, link: l) }
        }

        func collapse(_ text: String) -> String {
            text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
    }
}
