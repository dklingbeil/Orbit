import AppKit
import CoreGraphics
import ImageIO

/// A decoded image with orientation already applied, plus its metadata.
struct LoadedImage {
    var image: CGImage
    /// Metadata dictionaries safe to carry into a new file (orientation reset to "up").
    var metadata: [CFString: Any]
    var dpi: Double

    var hasAlpha: Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
    var width: Int { image.width }
    var height: Int { image.height }
}

enum ImageIOSupport {
    static func uti(for format: FileFormat) -> String? {
        switch format {
        case .jpg: return "public.jpeg"
        case .png: return "public.png"
        case .heic: return "public.heic"
        case .tiff: return "public.tiff"
        case .bmp: return "com.microsoft.bmp"
        case .gif: return "com.compuserve.gif"
        case .avif: return "public.avif"
        case .ico: return "com.microsoft.ico"
        default: return nil
        }
    }

    /// Formats that cannot store transparency.
    static func dropsAlpha(_ format: FileFormat) -> Bool { format == .jpg || format == .bmp }

    static func load(_ url: URL, maxPixelSize: Int? = nil) throws -> LoadedImage {
        if FormatDetector.format(for: url) == .svg { return try loadSVG(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw OrbitError.invalidInput("\(url.lastPathComponent) isn't a readable image.")
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0

        let image: CGImage?
        if orientation != 1 || maxPixelSize != nil {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize ?? max(width, height, 1),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image else { throw OrbitError.invalidInput("Couldn't decode \(url.lastPathComponent).") }

        var metadata: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = properties[key] { metadata[key] = value }
        }
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        metadata[kCGImagePropertyOrientation] = 1
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return LoadedImage(image: image, metadata: metadata, dpi: dpi > 0 ? dpi : 72)
    }

    /// Rasterizes an SVG at a comfortable size (2× its intrinsic size, at least 1024 px on the long edge).
    static func loadSVG(_ url: URL) throws -> LoadedImage {
        guard let svg = NSImage(contentsOf: url) else {
            throw OrbitError.invalidInput("Couldn't read the SVG \(url.lastPathComponent).")
        }
        var size = svg.size
        if size.width < 1 || size.height < 1 { size = CGSize(width: 512, height: 512) }
        let longEdge = max(size.width, size.height)
        let scale = min(4096, max(1024, longEdge * 2)) / longEdge
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw OrbitError.failed("Couldn't allocate an image buffer.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        svg.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw OrbitError.failed("Couldn't render the SVG.") }
        return LoadedImage(image: image, metadata: [:], dpi: 72 * scale)
    }

    static func write(_ image: CGImage, to url: URL, format: FileFormat, quality: Double, metadata: [CFString: Any]?,
                      extraOptions: [CFString: Any] = [:]) throws {
        guard let uti = uti(for: format) else { throw OrbitError.unsupported("writing \(format.name) with ImageIO") }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
            throw OrbitError.failed("This Mac can't write \(format.name) images.")
        }
        var options = metadata ?? [:]
        options[kCGImageDestinationLossyCompressionQuality] = quality
        for (key, value) in extraOptions { options[key] = value }
        let pixels = dropsAlpha(format) ? flattened(image) : image
        CGImageDestinationAddImage(destination, pixels, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw OrbitError.failed("Couldn't write \(url.lastPathComponent).")
        }
    }

    /// Composites onto white for formats without alpha.
    static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    /// Draws `image` into a new bitmap of the given size (high-quality interpolation).
    static func redraw(_ image: CGImage, width: Int, height: Int, transform: ((CGContext) -> Void)? = nil) -> CGImage? {
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        if let transform {
            transform(context)
        } else {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()
    }

    static func writePDF(_ images: [LoadedImage], to url: URL) throws {
        guard let first = images.first else { return }
        var mediaBox = pageRect(for: first)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw OrbitError.failed("Couldn't create \(url.lastPathComponent).")
        }
        for loaded in images {
            var box = pageRect(for: loaded)
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.draw(loaded.image, in: box)
            context.endPage()
        }
        context.closePDF()
    }

    private static func pageRect(for image: LoadedImage) -> CGRect {
        let scale = 72 / image.dpi
        return CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale)
    }
}
