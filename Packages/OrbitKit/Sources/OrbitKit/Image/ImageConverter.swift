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
            try await encodeWithFFmpeg(loaded.image, to: output, codec: avifCodec(quality: quality, ffmpeg: try context.ffmpeg), context: context)
        default:
            try ImageIOSupport.write(loaded.image, to: output, format: target, quality: quality, metadata: metadata)
        }
    }

    /// Still-image AV1: SVT-AV1 is fast; libaom is the fallback. (`-still-picture` is libaom-only.)
    static func avifCodec(quality: Double, ffmpeg: FFmpeg) -> [String] {
        let crf = Int((1 - quality) * 50 + 10)
        if ffmpeg.has("libsvtav1") {
            return ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libsvtav1", "-crf", "\(crf)", "-preset", "8", "-pix_fmt", "yuv420p"]
        }
        return ["-c:v", "libaom-av1", "-crf", "\(crf)", "-cpu-used", "6", "-still-picture", "1", "-pix_fmt", "yuv420p"]
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
