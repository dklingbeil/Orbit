import AppKit
import ImageIO

/// What this Mac can do right now: which external engines exist and which encoders they offer.
public final class Capabilities: @unchecked Sendable {
    public let ffmpeg: FFmpeg?
    public let cwebp: URL?
    public let libreOffice: LibreOffice?
    public let iwork: IWork
    public let imageIOWritableTypes: Set<String>

    public init(ffmpeg: FFmpeg?, cwebp: URL?, libreOffice: LibreOffice?, iwork: IWork, imageIOWritableTypes: Set<String>) {
        self.ffmpeg = ffmpeg
        self.cwebp = cwebp
        self.libreOffice = libreOffice
        self.iwork = iwork
        self.imageIOWritableTypes = imageIOWritableTypes
    }

    /// Probes the system. Runs a couple of quick subprocesses, so call it off the main thread.
    public static func detect(ffmpegPath: String? = nil) -> Capabilities {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return Capabilities(
            ffmpeg: FFmpeg.locate(override: ffmpegPath),
            cwebp: ProcessRunner.which("cwebp"),
            libreOffice: LibreOffice.locate(),
            iwork: IWork.detect(),
            imageIOWritableTypes: writable
        )
    }

    public var hasFFmpeg: Bool { ffmpeg != nil }

    public var webpEncoder: WebPEncoder? {
        if ffmpeg?.has("libwebp") == true { return .ffmpeg }
        if cwebp != nil { return .cwebp }
        return nil
    }

    public var avifEncoder: AVIFEncoder? {
        if imageIOWritableTypes.contains("public.avif") { return .imageIO }
        if let ffmpeg, ffmpeg.has("libsvtav1") || ffmpeg.has("libaom-av1") { return .ffmpeg }
        return nil
    }

    public var canRemoveBackground: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// Something that can turn office documents (pptx, xls, doc, iWork) into PDF or Office XML.
    public var hasOfficeRenderer: Bool { libreOffice != nil || iwork.keynote || iwork.pages || iwork.numbers }

    public enum WebPEncoder: Sendable { case ffmpeg, cwebp }
    public enum AVIFEncoder: Sendable { case imageIO, ffmpeg }

    /// Human-readable summary for settings screens and the CLI.
    public var summary: [(String, String)] {
        [
            ("FFmpeg", ffmpeg.map { "\($0.version) — \($0.url.path)" } ?? "Not found"),
            ("WebP encoder", webpEncoder.map { $0 == .ffmpeg ? "FFmpeg (libwebp)" : "cwebp" } ?? "Not available"),
            ("AVIF encoder", avifEncoder.map { $0 == .imageIO ? "ImageIO" : "FFmpeg" } ?? "Not available"),
            ("LibreOffice", libreOffice?.soffice.path ?? "Not found"),
            ("Pages", iwork.pages ? "Installed" : "Not installed"),
            ("Keynote", iwork.keynote ? "Installed" : "Not installed"),
            ("Numbers", iwork.numbers ? "Installed" : "Not installed"),
            ("Background removal", canRemoveBackground ? "Available" : "Requires macOS 14"),
        ]
    }
}
