import Foundation
import ImageIO

/// Format-neutral document model every document reader produces and every writer consumes.
public struct RichDocument: Sendable {
    public var title: String?
    public var blocks: [Block]

    public init(title: String? = nil, blocks: [Block] = []) {
        self.title = title
        self.blocks = blocks
    }

    public enum Block: Sendable {
        case heading(level: Int, spans: [Span])
        case paragraph([Span])
        /// Flattened list item; consecutive items form a list.
        case listItem(ordered: Bool, level: Int, spans: [Span])
        case code(String)
        case quote([Span])
        case image(RichImage)
        /// Rows of cells; the first row is treated as the header.
        case table([[[Span]]])
        case rule
        case pageBreak
    }

    /// Plain text of the whole document.
    public var plainText: String {
        var out: [String] = []
        for block in blocks {
            switch block {
            case .heading(_, let spans), .paragraph(let spans), .quote(let spans):
                out.append(spans.plainText)
            case .listItem(let ordered, let level, let spans):
                out.append(String(repeating: "  ", count: level) + (ordered ? "• " : "• ") + spans.plainText)
            case .code(let text):
                out.append(text)
            case .table(let rows):
                out.append(rows.map { $0.map(\.plainText).joined(separator: "\t") }.joined(separator: "\n"))
            case .image(let image):
                if let alt = image.alt, !alt.isEmpty { out.append("[\(alt)]") }
            case .rule, .pageBreak:
                continue
            }
        }
        return out.joined(separator: "\n\n")
    }

    public var isEmpty: Bool {
        blocks.allSatisfy {
            switch $0 {
            case .heading(_, let s), .paragraph(let s), .quote(let s), .listItem(_, _, let s): return s.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .code(let t): return t.isEmpty
            case .pageBreak, .rule: return true
            default: return false
            }
        }
    }

    /// Best guess at a title: explicit title, else the first heading.
    public var inferredTitle: String? {
        if let title, !title.isEmpty { return title }
        for block in blocks {
            if case .heading(_, let spans) = block { return spans.plainText }
        }
        return nil
    }
}

public struct Span: Sendable, Equatable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var link: String?

    public init(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.code = code
        self.link = link
    }

    func sameStyle(as other: Span) -> Bool {
        bold == other.bold && italic == other.italic && code == other.code && link == other.link
    }
}

public struct RichImage: Sendable {
    public var data: Data
    /// "png", "jpeg", "gif"…
    public var fileExtension: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var alt: String?

    public init(data: Data, fileExtension: String, pixelWidth: Int, pixelHeight: Int, alt: String? = nil) {
        self.data = data
        self.fileExtension = fileExtension
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.alt = alt
    }

    public var mimeType: String {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// Builds an image from encoded data, reading its pixel size with ImageIO.
    public static func from(data: Data, alt: String? = nil) -> RichImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let type = (CGImageSourceGetType(source) as String?) ?? "public.png"
        let ext: String
        switch type {
        case "public.jpeg": ext = "jpeg"
        case "com.compuserve.gif": ext = "gif"
        case "public.png": ext = "png"
        default:
            // Re-encode exotic formats (TIFF, HEIC…) as PNG so every writer can embed them.
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let png = PNGEncoder.encode(image) else { return nil }
            return RichImage(data: png, fileExtension: "png", pixelWidth: width, pixelHeight: height, alt: alt)
        }
        guard width > 0, height > 0 else { return nil }
        return RichImage(data: data, fileExtension: ext, pixelWidth: width, pixelHeight: height, alt: alt)
    }
}

enum PNGEncoder {
    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, ImageIOSupport.flattened(image),
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

extension Array where Element == Span {
    public var plainText: String { map(\.text).joined() }

    /// Merges adjacent spans with identical styling.
    func coalesced() -> [Span] {
        var result: [Span] = []
        for span in self where !span.text.isEmpty {
            if let last = result.last, last.sameStyle(as: span) {
                result[result.count - 1].text += span.text
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Removes the first `count` characters across spans (e.g. a list marker).
    func droppingPrefix(_ count: Int) -> [Span] {
        var remaining = count
        var result: [Span] = []
        for var span in self {
            if remaining > 0 {
                let drop = Swift.min(remaining, span.text.count)
                span.text = String(span.text.dropFirst(drop))
                remaining -= drop
            }
            if !span.text.isEmpty { result.append(span) }
        }
        return result
    }

    /// Trims leading/trailing whitespace across the span list.
    func trimmed() -> [Span] {
        var spans = coalesced()
        while let first = spans.first, first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { spans.removeFirst() }
        while let last = spans.last, last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { spans.removeLast() }
        if !spans.isEmpty {
            spans[0].text = String(spans[0].text.drop(while: { $0.isWhitespace }))
            let lastIndex = spans.count - 1
            while let c = spans[lastIndex].text.last, c.isWhitespace { spans[lastIndex].text.removeLast() }
        }
        return spans
    }
}
