import CoreGraphics
import Foundation
import PDFKit

enum PDFSupport {
    static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw OrbitError.invalidInput("\(url.lastPathComponent) isn't a readable PDF.")
        }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password) else {
                throw password == nil ? OrbitError.passwordRequired : OrbitError.wrongPassword
            }
        }
        return document
    }
}

enum PDFRenderer {
    /// Renders one page to a bitmap at `dpi`, on white, honoring page rotation.
    static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        guard let cgPage = page.pageRef else { return nil }
        let box = cgPage.getBoxRect(.cropBox)
        let rotated = cgPage.rotationAngle % 180 != 0
        let pointSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = dpi / 72
        let width = max(1, Int((pointSize.width * scale).rounded()))
        let height = max(1, Int((pointSize.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        let transform = cgPage.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pointSize), rotate: 0, preserveAspectRatio: true)
        context.concatenate(transform)
        context.drawPDFPage(cgPage)
        return context.makeImage()
    }

    /// PDF → JPG/PNG. One file for single-page PDFs, otherwise a folder with every page.
    static func renderPages(of input: URL, as target: FileFormat, base: String, context: JobContext) throws -> [URL] {
        let document = try PDFSupport.open(input, password: context.parameters.password)
        let count = document.pageCount
        guard count > 0 else { throw OrbitError.invalidInput("The PDF has no pages.") }
        let quality = context.settings.imageQuality
        let digits = String(count).count

        let folder: URL? = count > 1 ? try context.outputFolder(named: "\(base) \(target.name)") : nil
        var outputs: [URL] = []
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let image = render(page, dpi: context.settings.pdfRenderDPI) else { continue }
            let url: URL
            if let folder {
                url = folder.appendingPathComponent("\(base)-\(String(format: "%0\(digits)d", index + 1)).\(target.fileExtension)")
            } else {
                url = context.output(base: base, ext: target.fileExtension)
            }
            try ImageIOSupport.write(image, to: url, format: target, quality: quality,
                                     metadata: [kCGImagePropertyDPIWidth: context.settings.pdfRenderDPI,
                                                kCGImagePropertyDPIHeight: context.settings.pdfRenderDPI])
            outputs.append(url)
            context.progress(Double(index + 1) / Double(count))
        }
        return folder.map { [$0] } ?? outputs
    }
}

/// PDF → PPTX: each page becomes a full-bleed slide image.
enum PDFToPPTX {
    static func convert(_ input: URL, base: String, context: JobContext) throws -> URL {
        let document = try PDFSupport.open(input, password: context.parameters.password)
        guard document.pageCount > 0, let first = document.page(at: 0) else { throw OrbitError.invalidInput("The PDF has no pages.") }
        let firstBounds = first.bounds(for: .cropBox)
        let landscapeSize = first.rotation % 180 != 0 ? CGSize(width: firstBounds.height, height: firstBounds.width) : firstBounds.size
        var slides: [Data] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let image = PDFRenderer.render(page, dpi: 200),
                  let data = PNGEncoder.encode(image) else { continue }
            slides.append(data)
            context.progress(Double(index + 1) / Double(document.pageCount) * 0.9)
        }
        let output = context.output(base: base, ext: "pptx")
        try PPTXWriter.write(slideImages: slides, slideSize: landscapeSize, to: output)
        return output
    }
}
