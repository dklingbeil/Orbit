import CoreGraphics
import Foundation
import ImageIO

/// Still-image conversions using ImageIO, with FFmpeg/cwebp for WebP (and AVIF on older systems).
enum ImageConverter {
    static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, base: String, context: JobContext) async throws -> URL {
        let loaded = try ImageIOSupport.load(input)
        let output = context.output(base: base, ext: target.fileExtension)
        try await write(loaded, as: target, to: output, quality: context.settings.imageQuality,
                        keepMetadata: context.settings.preserveImageMetadata, context: context)
        return output
    }

    /// Writes `loaded` in any supported still-image format (including PDF and WebP).
    static func write(_ loaded: LoadedImage, as target: FileFormat, to output: URL, quality: Double,
                      keepMetadata: Bool, context: JobContext) async throws {
        let metadata = keepMetadata ? loaded.metadata : [:]
        switch target {
        case .pdf:
            try ImageIOSupport.writePDF([loaded], to: output)
        case .webp:
            try await encodeWebP(loaded.image, to: output, quality: quality, context: context)
        case .avif where context.capabilities.avifEncoder == .ffmpeg:
            try await encodeWithFFmpeg(loaded.image, to: output, codec: ["-c:v", context.capabilities.ffmpeg?.has("libsvtav1") == true ? "libsvtav1" : "libaom-av1",
                                                                          "-crf", "\(Int((1 - quality) * 50 + 10))", "-still-picture", "1"], context: context)
        default:
            try ImageIOSupport.write(loaded.image, to: output, format: target, quality: quality, metadata: metadata)
        }
    }

    static func encodeWebP(_ image: CGImage, to output: URL, quality: Double, context: JobContext) async throws {
        let caps = context.capabilities
        switch caps.webpEncoder {
        case .ffmpeg?:
            try await encodeWithFFmpeg(image, to: output, codec: ["-c:v", "libwebp", "-quality", "\(Int(quality * 100))", "-compression_level", "4"],
                                       context: context)
        case .cwebp?:
            let png = try context.scratch().appendingPathComponent("source.png")
            try ImageIOSupport.write(image, to: png, format: .png, quality: 1, metadata: nil)
            try await ProcessRunner.checked(caps.cwebp!, ["-quiet", "-q", "\(Int(quality * 100))", "-alpha_q", "100", png.path, "-o", output.path],
                                            toolName: "cwebp")
        case nil:
            throw OrbitError.missingTool("WebP needs FFmpeg with libwebp or the cwebp tool (brew install webp).")
        }
    }

    private static func encodeWithFFmpeg(_ image: CGImage, to output: URL, codec: [String], context: JobContext) async throws {
        let png = try context.scratch().appendingPathComponent("source.png")
        try ImageIOSupport.write(image, to: png, format: .png, quality: 1, metadata: nil)
        try await context.ffmpeg.run(["-i", png.path, "-frames:v", "1"] + codec + [output.path], duration: nil)
    }
}
