import AppKit

/// Documents and e-books: read anything into a RichDocument, write it back out in the target format.
enum DocumentConverter {
    static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, base: String, context: JobContext) async throws -> URL {
        let output = context.output(base: base, ext: target.fileExtension)
        let caps = context.capabilities

        // High-fidelity paths through office apps when they're available.
        if target == .pdf {
            if source == .pages, caps.iwork.pages {
                try await IWork.export(input, with: .pages, as: .pdf, to: output)
                return output
            }
            if [.docx, .doc, .odt, .pages].contains(source), let office = caps.libreOffice {
                let produced = try await office.convert(input, to: "pdf", outputDirectory: try context.scratch())
                try FileManager.default.moveItem(at: produced, to: output)
                return output
            }
        }
        if source == .pages, target == .docx, caps.iwork.pages {
            try await IWork.export(input, with: .pages, as: .word, to: output)
            return output
        }
        if target == .pages {
            let docx: URL
            if source == .docx {
                docx = input
            } else {
                docx = try context.scratch().appendingPathComponent("\(base).docx")
                let document = try await read(input, format: source, context: context)
                try DOCXWriter.write(document, to: docx)
            }
            try await IWork.saveNative(docx, with: .pages, to: output)
            return output
        }

        context.progress(nil)
        let document = try await read(input, format: source, context: context)
        guard !document.isEmpty else { throw OrbitError.failed("\(input.lastPathComponent) doesn't contain any text to convert.") }
        try write(document, as: target, to: output)
        return output
    }

    static func read(_ input: URL, format: FileFormat, context: JobContext) async throws -> RichDocument {
        switch format {
        case .md:
            return MarkdownReader.read(try readText(input), baseURL: input.deletingLastPathComponent())
        case .txt:
            return plainText(try readText(input))
        case .html:
            let directory = input.deletingLastPathComponent()
            return try HTMLReader.read(try Data(contentsOf: input)) { src in
                guard !src.hasPrefix("http:"), !src.hasPrefix("https:") else { return nil }
                let path = src.removingPercentEncoding ?? src
                return try? Data(contentsOf: path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path))
            }
        case .docx:
            return try DOCXReader.read(input)
        case .epub:
            return try EPUBReader.read(input)
        case .pdf:
            return try PDFTextExtractor.extract(input, password: context.parameters.password) { context.progress($0 * 0.8) }
        case .rtf, .rtfd, .doc, .odt:
            let attributed = try NSAttributedString(url: input, options: [:], documentAttributes: nil)
            return AttributedBridge.read(attributed)
        case .textClipping:
            return try TextClipping.read(input)
        case .pages:
            let scratch = try context.scratch()
            if context.capabilities.iwork.pages {
                let docx = scratch.appendingPathComponent("pages.docx")
                try await IWork.export(input, with: .pages, as: .word, to: docx)
                return try DOCXReader.read(docx)
            }
            guard let office = context.capabilities.libreOffice else {
                throw OrbitError.missingTool("Reading Pages documents requires Pages or LibreOffice.")
            }
            return try DOCXReader.read(try await office.convert(input, to: "docx", outputDirectory: scratch))
        default:
            throw OrbitError.unsupported("reading \(format.name) as a document")
        }
    }

    static func write(_ document: RichDocument, as target: FileFormat, to output: URL) throws {
        switch target {
        case .md:
            try MarkdownWriter.write(document).write(to: output, atomically: true, encoding: .utf8)
        case .txt:
            try (document.plainText + "\n").write(to: output, atomically: true, encoding: .utf8)
        case .html:
            try HTMLWriter.document(document).write(to: output, atomically: true, encoding: .utf8)
        case .docx:
            try DOCXWriter.write(document, to: output)
        case .epub:
            try EPUBWriter.write(document, to: output)
        case .rtf:
            let attributed = AttributedBridge.attributedString(document, contentWidth: PageGeometry.pageSize.width - 128)
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: output)
        case .pdf:
            let attributed = AttributedBridge.attributedString(document, contentWidth: PageGeometry.pageSize.width - 128)
            try PDFPaginator.write(attributed, to: output)
        default:
            throw OrbitError.unsupported("writing \(target.name) documents")
        }
    }

    static func readText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        if let text = try? String(contentsOf: url, encoding: .windowsCP1252) { return text }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    static func plainText(_ text: String) -> RichDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return RichDocument(blocks: paragraphs.map { .paragraph([Span($0)]) })
    }
}

/// Finder text clippings (.textClipping): a property list holding pasteboard flavors.
enum TextClipping {
    static func read(_ url: URL) throws -> RichDocument {
        let data = try Data(contentsOf: url)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let flavors = plist["UTI-Data"] as? [String: Any] {
            if let rtf = flavors["public.rtf"] as? Data, let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                return AttributedBridge.read(attributed)
            }
            for key in ["public.utf8-plain-text", "public.plain-text", "public.utf16-plain-text", "public.url"] {
                if let string = flavors[key] as? String { return DocumentConverter.plainText(string) }
                if let raw = flavors[key] as? Data {
                    let encoding: String.Encoding = key.contains("utf16") ? .utf16 : .utf8
                    if let string = String(data: raw, encoding: encoding) { return DocumentConverter.plainText(string) }
                }
            }
        }
        // Very old clippings keep their text in the resource fork.
        let fork = url.appendingPathComponent("..namedfork/rsrc")
        if let rsrc = try? Data(contentsOf: fork), !rsrc.isEmpty {
            let text = String(decoding: rsrc, as: UTF8.self).filter { !$0.isASCII || $0.isLetter || $0.isPunctuation || $0.isWhitespace || $0.isNumber }
            if !text.isEmpty { return DocumentConverter.plainText(text) }
        }
        throw OrbitError.invalidInput("Couldn't read the text clipping.")
    }
}
