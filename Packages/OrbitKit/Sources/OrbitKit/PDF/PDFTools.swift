import AppKit
import Foundation
import PDFKit

enum PDFTools {
    static func run(_ tool: ToolID, option: String?, inputs: [URL], context: JobContext) async throws -> [URL] {
        if tool == .pdfMerge { return [try merge(inputs, context: context)] }
        var outputs: [URL] = []
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            context.progress(Double(index) / Double(inputs.count))
            outputs += try runOne(tool, option: option, input: input, context: context)
        }
        return outputs
    }

    private static func runOne(_ tool: ToolID, option: String?, input: URL, context: JobContext) throws -> [URL] {
        let base = OutputNaming.baseName(of: input)
        switch tool {
        case .pdfCompress:
            let document = try PDFSupport.open(input, password: context.parameters.password)
            let output = context.output(base: "\(base)-compressed", ext: "pdf")
            guard #available(macOS 13.4, *) else { throw OrbitError.unsupported("PDF compression requires macOS 13.4") }
            var options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
            if option == "strong" { options[.optimizeImagesForScreenOption] = true }
            guard document.write(to: output, withOptions: options) else { throw OrbitError.failed("Couldn't write the compressed PDF.") }
            let before = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let after = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if before > 0, after >= before {
                try? FileManager.default.removeItem(at: output)
                throw OrbitError.failed("\(input.lastPathComponent) is already about as small as it can get.")
            }
            return [output]

        case .pdfSplit:
            let document = try PDFSupport.open(input, password: context.parameters.password)
            let count = document.pageCount
            guard count > 1 else { throw OrbitError.invalidInput("The PDF has only one page.") }
            let ranges: [ClosedRange<Int>]
            if option == "custom" {
                ranges = try parseRanges(context.parameters.text ?? "", pageCount: count)
            } else {
                ranges = (1...count).map { $0...$0 }
            }
            let folder = try context.outputFolder(named: "\(base) split")
            let digits = String(count).count
            for range in ranges {
                let part = PDFDocument()
                for pageNumber in range {
                    if let page = document.page(at: pageNumber - 1)?.copy() as? PDFPage {
                        part.insert(page, at: part.pageCount)
                    }
                }
                let label = range.count == 1
                    ? String(format: "%0\(digits)d", range.lowerBound)
                    : "\(range.lowerBound)-\(range.upperBound)"
                let url = folder.appendingPathComponent("\(base)-\(range.count == 1 ? "page" : "pages")-\(label).pdf")
                guard part.write(to: url) else { throw OrbitError.failed("Couldn't write \(url.lastPathComponent).") }
            }
            return [folder]

        case .pdfRotate:
            let document = try PDFSupport.open(input, password: context.parameters.password)
            let delta: Int = option == "left" ? -90 : option == "180" ? 180 : 90
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                page.rotation = ((page.rotation + delta) % 360 + 360) % 360
            }
            let output = context.output(base: "\(base)-rotated", ext: "pdf")
            guard document.write(to: output) else { throw OrbitError.failed("Couldn't write the rotated PDF.") }
            return [output]

        case .pdfOCR:
            let document = try PDFSupport.open(input, password: context.parameters.password)
            let output = context.output(base: "\(base)-searchable", ext: "pdf")
            guard document.write(to: output, withOptions: [.saveTextFromOCROption: true]) else {
                throw OrbitError.failed("Couldn't write the searchable PDF.")
            }
            return [output]

        case .pdfProtect:
            guard let password = context.parameters.password, !password.isEmpty else {
                throw OrbitError.invalidInput("A password is required.")
            }
            let document = try PDFSupport.open(input)
            let output = context.output(base: "\(base)-protected", ext: "pdf")
            let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
            guard document.write(to: output, withOptions: options) else { throw OrbitError.failed("Couldn't write the protected PDF.") }
            return [output]

        case .pdfUnlock:
            guard let document = PDFDocument(url: input) else { throw OrbitError.invalidInput("\(input.lastPathComponent) isn't a readable PDF.") }
            guard document.isEncrypted || document.isLocked else {
                throw OrbitError.invalidInput("\(input.lastPathComponent) isn't password-protected.")
            }
            if document.isLocked {
                guard let password = context.parameters.password, document.unlock(withPassword: password) else {
                    throw OrbitError.wrongPassword
                }
            }
            // Re-creating the document drops the encryption dictionary.
            let unlocked = PDFDocument()
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage { unlocked.insert(page, at: unlocked.pageCount) }
            }
            let output = context.output(base: "\(base)-unlocked", ext: "pdf")
            guard unlocked.write(to: output) else { throw OrbitError.failed("Couldn't write the unlocked PDF.") }
            return [output]

        default:
            throw OrbitError.unsupported(tool.rawValue)
        }
    }

    /// Merges PDFs (and images) in name order.
    private static func merge(_ inputs: [URL], context: JobContext) throws -> URL {
        guard inputs.count >= 2 else { throw OrbitError.invalidInput("Choose at least two files to merge.") }
        let sorted = inputs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let merged = PDFDocument()
        for (index, input) in sorted.enumerated() {
            try Task.checkCancellation()
            if FormatDetector.format(for: input)?.category == .image {
                let loaded = try ImageIOSupport.load(input)
                let image = NSImage(cgImage: loaded.image, size: NSSize(width: Double(loaded.width) * 72 / loaded.dpi,
                                                                         height: Double(loaded.height) * 72 / loaded.dpi))
                if let page = PDFPage(image: image) { merged.insert(page, at: merged.pageCount) }
            } else {
                let document = try PDFSupport.open(input, password: context.parameters.password)
                for pageIndex in 0..<document.pageCount {
                    if let page = document.page(at: pageIndex)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
                }
            }
            context.progress(Double(index + 1) / Double(sorted.count))
        }
        let output = context.output(base: "\(OutputNaming.baseName(of: sorted[0]))-merged", ext: "pdf")
        guard merged.write(to: output) else { throw OrbitError.failed("Couldn't write the merged PDF.") }
        return output
    }

    /// "1-3, 5, 7-" → [1...3, 5...5, 7...last]
    static func parseRanges(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let bounds = trimmed.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let lower: Int?, upper: Int?
            if bounds.count == 1 {
                lower = Int(bounds[0]); upper = lower
            } else if bounds.count == 2 {
                lower = bounds[0].isEmpty ? 1 : Int(bounds[0])
                upper = bounds[1].isEmpty ? pageCount : Int(bounds[1])
            } else {
                lower = nil; upper = nil
            }
            guard let lower, let upper, lower >= 1, upper <= pageCount, lower <= upper else {
                throw OrbitError.invalidInput("“\(trimmed)” isn't a valid page range (the PDF has \(pageCount) pages).")
            }
            ranges.append(lower...upper)
        }
        guard !ranges.isEmpty else { throw OrbitError.invalidInput("Enter page ranges such as 1-3, 4, 5-8.") }
        return ranges
    }
}
