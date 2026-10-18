import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

enum ImageTools {
    static func run(_ tool: ToolID, option: String?, inputs: [URL], context: JobContext) async throws -> [URL] {
        if tool == .imagesToPDF {
            let sorted = inputs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let images = try sorted.map { try ImageIOSupport.load($0) }
            let output = context.output(base: "\(OutputNaming.baseName(of: sorted[0]))-combined", ext: "pdf")
            try ImageIOSupport.writePDF(images, to: output)
            return [output]
        }

        var outputs: [URL] = []
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            context.progress(Double(index) / Double(inputs.count))
            outputs.append(try await runOne(tool, option: option, input: input, context: context))
        }
        return outputs
    }

    /// Format a tool writes back: the source format when we can encode it, otherwise PNG/JPG.
    private static func outputFormat(for source: FileFormat, context: JobContext) -> FileFormat {
        switch source {
        case .svg, .psd, .ico: return .png
        case .raw: return .jpg
        case .webp: return context.capabilities.webpEncoder == nil ? .png : .webp
        case .avif: return context.capabilities.avifEncoder == nil ? .png : .avif
        case .heic: return context.capabilities.canEncodeHEIC ? .heic : .jpg
        default: return source
        }
    }

    private static func runOne(_ tool: ToolID, option: String?, input: URL, context: JobContext) async throws -> URL {
        let source = FormatDetector.format(for: input) ?? .png
        let base = OutputNaming.baseName(of: input)
        var format = outputFormat(for: source, context: context)
        let quality = context.settings.imageQuality

        switch tool {
        case .imageCompress:
            return try await compress(input, source: source, option: option, base: base, context: context)

        case .imageResize:
            var loaded = try ImageIOSupport.load(input)
            let (width, height) = try targetSize(option: option, text: context.parameters.text, width: loaded.width, height: loaded.height)
            guard let resized = ImageIOSupport.redraw(loaded.image, width: width, height: height) else {
                throw OrbitError.failed("Couldn't resize the image.")
            }
            loaded.image = resized
            let output = context.output(base: "\(base)-\(width)x\(height)", ext: format.fileExtension)
            try await ImageConverter.write(loaded, as: format, to: output, quality: quality, keepMetadata: true, context: context)
            return output

        case .imageCrop:
            var loaded = try ImageIOSupport.load(input)
            guard let rect = context.parameters.cropRect?.integral,
                  let cropped = loaded.image.cropping(to: rect.intersection(CGRect(x: 0, y: 0, width: loaded.width, height: loaded.height))) else {
                throw OrbitError.invalidInput("No crop area was chosen.")
            }
            loaded.image = cropped
            let output = context.output(base: "\(base)-cropped", ext: format.fileExtension)
            try await ImageConverter.write(loaded, as: format, to: output, quality: quality, keepMetadata: true, context: context)
            return output

        case .imageRotate:
            var loaded = try ImageIOSupport.load(input)
            loaded.image = try rotate(loaded.image, option: option ?? "right")
            let suffix = option == "flipH" || option == "flipV" ? "flipped" : "rotated"
            let output = context.output(base: "\(base)-\(suffix)", ext: format.fileExtension)
            try await ImageConverter.write(loaded, as: format, to: output, quality: quality, keepMetadata: true, context: context)
            return output

        case .imageRemoveBackground:
            guard #available(macOS 14.0, *) else { throw OrbitError.unsupported("Background removal requires macOS 14") }
            let loaded = try ImageIOSupport.load(input)
            let cutout = try removeBackground(loaded.image)
            let output = context.output(base: "\(base)-cutout", ext: "png")
            try ImageIOSupport.write(cutout, to: output, format: .png, quality: 1, metadata: nil)
            return output

        case .imageStripMetadata:
            if source == .svg { throw OrbitError.unsupported("SVG files don't carry photo metadata") }
            format = outputFormat(for: source, context: context)
            let output = context.output(base: "\(base)-clean", ext: format.fileExtension)
            if format == source, try stripLosslessly(input, to: output) { return output }
            let loaded = try ImageIOSupport.load(input)
            try await ImageConverter.write(loaded, as: format, to: output, quality: max(quality, 0.92), keepMetadata: false, context: context)
            return output

        case .imageExtractText:
            let loaded = try ImageIOSupport.load(input)
            let text = try TextRecognizer.text(in: loaded.image)
            guard !text.isEmpty else { throw OrbitError.failed("No text was found in \(input.lastPathComponent).") }
            let output = context.output(base: base, ext: "txt")
            try text.write(to: output, atomically: true, encoding: .utf8)
            return output

        default:
            throw OrbitError.unsupported(tool.rawValue)
        }
    }

    // MARK: Compress

    private static func compress(_ input: URL, source: FileFormat, option: String?, base: String, context: JobContext) async throws -> URL {
        let level = option ?? "medium"
        let quality: Double = level == "light" ? 0.75 : level == "strong" ? 0.45 : 0.6
        let originalSize = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var output: URL

        switch source {
        case .png, .gif:
            output = context.output(base: "\(base)-compressed", ext: source.fileExtension)
            let colors = level == "light" ? 256 : level == "strong" ? 64 : 128
            if let ffmpeg = context.capabilities.ffmpeg {
                let filter: String
                if source == .gif {
                    filter = "split[a][b];[a]palettegen=max_colors=\(colors):stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
                    try await ffmpeg.run(["-i", input.path, "-filter_complex", filter, "-loop", "0", output.path], duration: nil)
                } else {
                    filter = "split[a][b];[a]palettegen=max_colors=\(colors):reserve_transparent=1:stats_mode=single[p];[b][p]paletteuse=dither=sierra2_4a:alpha_threshold=128"
                    try await ffmpeg.run(["-i", input.path, "-filter_complex", filter, "-frames:v", "1", "-update", "1",
                                          "-c:v", "png", "-pred", "mixed", output.path], duration: nil)
                }
            } else {
                let loaded = try ImageIOSupport.load(input)
                try ImageIOSupport.write(loaded.image, to: output, format: source, quality: 1, metadata: nil)
            }

        default:
            var loaded = try ImageIOSupport.load(input)
            if level == "strong", max(loaded.width, loaded.height) > 2560 {
                let scale = 2560 / Double(max(loaded.width, loaded.height))
                if let smaller = ImageIOSupport.redraw(loaded.image, width: Int(Double(loaded.width) * scale), height: Int(Double(loaded.height) * scale)) {
                    loaded.image = smaller
                }
            }
            var format = outputFormat(for: source, context: context)
            if format == .bmp { format = .png }
            output = context.output(base: "\(base)-compressed", ext: format.fileExtension)
            let extra: [CFString: Any] = format == .tiff
                ? [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] : [:]
            if format == .tiff {
                try ImageIOSupport.write(loaded.image, to: output, format: .tiff, quality: quality, metadata: nil, extraOptions: extra)
            } else {
                try await ImageConverter.write(loaded, as: format, to: output, quality: quality, keepMetadata: level == "light", context: context)
            }
        }

        let newSize = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if originalSize > 0, newSize >= originalSize {
            try? FileManager.default.removeItem(at: output)
            throw OrbitError.failed("\(input.lastPathComponent) is already compressed about as much as it can be.")
        }
        return output
    }

    // MARK: Resize

    static func targetSize(option: String?, text: String?, width: Int, height: Int) throws -> (Int, Int) {
        func scaled(_ factor: Double) -> (Int, Int) {
            (max(1, Int((Double(width) * factor).rounded())), max(1, Int((Double(height) * factor).rounded())))
        }
        if let option, option != "custom", let percent = Double(option) { return scaled(percent / 100) }
        let raw = (text ?? "").trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
        guard !raw.isEmpty else { throw OrbitError.invalidInput("Enter a size such as 50%, 1920x1080, 1200w or 800h.") }
        if raw.hasSuffix("%"), let percent = Double(raw.dropLast()) { return scaled(percent / 100) }
        if raw.hasSuffix("w"), let w = Double(raw.dropLast()) { return scaled(w / Double(width)) }
        if raw.hasSuffix("h"), let h = Double(raw.dropLast()) { return scaled(h / Double(height)) }
        let parts = raw.split(whereSeparator: { $0 == "x" || $0 == "×" || $0 == "*" })
        if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
            return scaled(min(w / Double(width), h / Double(height)))
        }
        if let w = Double(raw) { return scaled(w / Double(width)) }
        throw OrbitError.invalidInput("“\(text ?? "")” isn't a size Orbit understands. Try 50%, 1920x1080, 1200w or 800h.")
    }

    // MARK: Rotate

    static func rotate(_ image: CGImage, option: String) throws -> CGImage {
        let w = image.width, h = image.height
        let swaps = option == "left" || option == "right"
        let outW = swaps ? h : w, outH = swaps ? w : h
        let result = ImageIOSupport.redraw(image, width: outW, height: outH) { ctx in
            switch option {
            case "right":
                ctx.translateBy(x: 0, y: CGFloat(outH))
                ctx.rotate(by: -.pi / 2)
            case "left":
                ctx.translateBy(x: CGFloat(outW), y: 0)
                ctx.rotate(by: .pi / 2)
            case "180":
                ctx.translateBy(x: CGFloat(outW), y: CGFloat(outH))
                ctx.rotate(by: .pi)
            case "flipH":
                ctx.translateBy(x: CGFloat(outW), y: 0)
                ctx.scaleBy(x: -1, y: 1)
            case "flipV":
                ctx.translateBy(x: 0, y: CGFloat(outH))
                ctx.scaleBy(x: 1, y: -1)
            default:
                break
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        guard let result else { throw OrbitError.failed("Couldn't rotate the image.") }
        return result
    }

    // MARK: Background removal

    @available(macOS 14.0, *)
    static func removeBackground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw OrbitError.failed("Couldn't find a subject to cut out.")
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let output = context.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8,
                                                 colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw OrbitError.failed("Couldn't render the cutout.")
        }
        return output
    }

    // MARK: Metadata

    /// Copies the image data untouched while dropping EXIF/GPS/XMP. Returns false if ImageIO can't do it for this format.
    private static func stripLosslessly(_ input: URL, to output: URL) throws -> Bool {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else { return false }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber) ?? 1
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageDestinationOrientation: orientation,
        ]
        var error: Unmanaged<CFError>?
        let ok = CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error)
        if !ok { try? FileManager.default.removeItem(at: output) }
        return ok
    }
}
