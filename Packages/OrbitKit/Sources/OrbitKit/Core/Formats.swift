import Foundation
import UniformTypeIdentifiers

/// Broad family a file belongs to. Drives which conversions and tools are offered.
public enum FormatCategory: String, CaseIterable, Sendable {
    case image, audio, video, pdf, document, ebook, slides, spreadsheet, subtitle, archive, folder

    public var displayName: String {
        switch self {
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Video"
        case .pdf: return "PDF"
        case .document: return "Document"
        case .ebook: return "E-book"
        case .slides: return "Slides"
        case .spreadsheet: return "Spreadsheet"
        case .subtitle: return "Subtitles"
        case .archive: return "Archive"
        case .folder: return "Folder"
        }
    }
}

/// A concrete file format Orbit can read and/or write.
public struct FileFormat: Hashable, Sendable, Identifiable, CustomStringConvertible {
    public let id: String
    /// Short label shown on the wheel ("JPG", "MD", "Pages").
    public let name: String
    public let category: FormatCategory
    /// Lowercased extensions, preferred first. May contain multi-part extensions such as "tar.gz".
    public let extensions: [String]

    public init(id: String, name: String, category: FormatCategory, extensions: [String]) {
        self.id = id
        self.name = name
        self.category = category
        self.extensions = extensions
    }

    public var fileExtension: String { extensions.first ?? id }
    public var description: String { name }

    public static func == (lhs: FileFormat, rhs: FileFormat) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public extension FileFormat {
    // MARK: Images
    static let jpg = FileFormat(id: "jpg", name: "JPG", category: .image, extensions: ["jpg", "jpeg", "jpe", "jfif"])
    static let png = FileFormat(id: "png", name: "PNG", category: .image, extensions: ["png"])
    static let webp = FileFormat(id: "webp", name: "WebP", category: .image, extensions: ["webp"])
    static let heic = FileFormat(id: "heic", name: "HEIC", category: .image, extensions: ["heic", "heif", "hif"])
    static let tiff = FileFormat(id: "tiff", name: "TIFF", category: .image, extensions: ["tiff", "tif"])
    static let avif = FileFormat(id: "avif", name: "AVIF", category: .image, extensions: ["avif"])
    static let bmp = FileFormat(id: "bmp", name: "BMP", category: .image, extensions: ["bmp", "dib"])
    static let gif = FileFormat(id: "gif", name: "GIF", category: .image, extensions: ["gif"])
    static let svg = FileFormat(id: "svg", name: "SVG", category: .image, extensions: ["svg"])
    static let psd = FileFormat(id: "psd", name: "PSD", category: .image, extensions: ["psd"])
    static let ico = FileFormat(id: "ico", name: "ICO", category: .image, extensions: ["ico"])
    static let raw = FileFormat(id: "raw", name: "RAW", category: .image,
                                extensions: ["dng", "cr2", "cr3", "nef", "nrw", "arw", "raf", "orf", "rw2", "srw", "pef"])

    // MARK: Audio
    static let mp3 = FileFormat(id: "mp3", name: "MP3", category: .audio, extensions: ["mp3"])
    static let m4a = FileFormat(id: "m4a", name: "M4A", category: .audio, extensions: ["m4a", "m4b"])
    static let aac = FileFormat(id: "aac", name: "AAC", category: .audio, extensions: ["aac"])
    static let wav = FileFormat(id: "wav", name: "WAV", category: .audio, extensions: ["wav", "wave"])
    static let flac = FileFormat(id: "flac", name: "FLAC", category: .audio, extensions: ["flac"])
    static let ogg = FileFormat(id: "ogg", name: "OGG", category: .audio, extensions: ["ogg", "oga"])
    static let opus = FileFormat(id: "opus", name: "Opus", category: .audio, extensions: ["opus"])
    static let aiff = FileFormat(id: "aiff", name: "AIFF", category: .audio, extensions: ["aiff", "aif", "aifc"])
    static let wma = FileFormat(id: "wma", name: "WMA", category: .audio, extensions: ["wma"])
    static let caf = FileFormat(id: "caf", name: "CAF", category: .audio, extensions: ["caf"])

    // MARK: Video
    static let mp4 = FileFormat(id: "mp4", name: "MP4", category: .video, extensions: ["mp4", "m4v"])
    static let mov = FileFormat(id: "mov", name: "MOV", category: .video, extensions: ["mov", "qt"])
    static let mkv = FileFormat(id: "mkv", name: "MKV", category: .video, extensions: ["mkv"])
    static let webm = FileFormat(id: "webm", name: "WebM", category: .video, extensions: ["webm"])
    static let avi = FileFormat(id: "avi", name: "AVI", category: .video, extensions: ["avi"])
    static let wmv = FileFormat(id: "wmv", name: "WMV", category: .video, extensions: ["wmv", "asf"])
    static let flv = FileFormat(id: "flv", name: "FLV", category: .video, extensions: ["flv"])
    static let mpeg = FileFormat(id: "mpeg", name: "MPEG", category: .video, extensions: ["mpg", "mpeg", "m2v", "vob"])
    static let mts = FileFormat(id: "mts", name: "MTS", category: .video, extensions: ["mts", "m2ts", "ts"])
    static let threeGP = FileFormat(id: "3gp", name: "3GP", category: .video, extensions: ["3gp", "3g2"])

    // MARK: PDF
    static let pdf = FileFormat(id: "pdf", name: "PDF", category: .pdf, extensions: ["pdf"])

    // MARK: Documents
    static let docx = FileFormat(id: "docx", name: "DOCX", category: .document, extensions: ["docx", "docm", "dotx"])
    static let doc = FileFormat(id: "doc", name: "DOC", category: .document, extensions: ["doc", "dot"])
    static let pages = FileFormat(id: "pages", name: "Pages", category: .document, extensions: ["pages"])
    static let md = FileFormat(id: "md", name: "MD", category: .document, extensions: ["md", "markdown", "mdown", "mkd", "mkdn"])
    static let txt = FileFormat(id: "txt", name: "TXT", category: .document, extensions: ["txt", "text"])
    static let rtf = FileFormat(id: "rtf", name: "RTF", category: .document, extensions: ["rtf"])
    static let rtfd = FileFormat(id: "rtfd", name: "RTFD", category: .document, extensions: ["rtfd"])
    static let textClipping = FileFormat(id: "textclipping", name: "Clipping", category: .document, extensions: ["textclipping"])
    static let html = FileFormat(id: "html", name: "HTML", category: .document, extensions: ["html", "htm", "xhtml"])
    static let odt = FileFormat(id: "odt", name: "ODT", category: .document, extensions: ["odt"])

    // MARK: E-books
    static let epub = FileFormat(id: "epub", name: "EPUB", category: .ebook, extensions: ["epub"])

    // MARK: Slides
    static let pptx = FileFormat(id: "pptx", name: "PPTX", category: .slides, extensions: ["pptx", "pptm", "ppsx"])
    static let ppt = FileFormat(id: "ppt", name: "PPT", category: .slides, extensions: ["ppt", "pps"])
    static let key = FileFormat(id: "key", name: "Keynote", category: .slides, extensions: ["key"])
    static let odp = FileFormat(id: "odp", name: "ODP", category: .slides, extensions: ["odp"])

    // MARK: Spreadsheets
    static let xlsx = FileFormat(id: "xlsx", name: "XLSX", category: .spreadsheet, extensions: ["xlsx", "xlsm"])
    static let xls = FileFormat(id: "xls", name: "XLS", category: .spreadsheet, extensions: ["xls"])
    static let ods = FileFormat(id: "ods", name: "ODS", category: .spreadsheet, extensions: ["ods"])
    static let csv = FileFormat(id: "csv", name: "CSV", category: .spreadsheet, extensions: ["csv"])
    static let tsv = FileFormat(id: "tsv", name: "TSV", category: .spreadsheet, extensions: ["tsv", "tab"])
    static let numbers = FileFormat(id: "numbers", name: "Numbers", category: .spreadsheet, extensions: ["numbers"])

    // MARK: Subtitles
    static let srt = FileFormat(id: "srt", name: "SRT", category: .subtitle, extensions: ["srt"])
    static let vtt = FileFormat(id: "vtt", name: "VTT", category: .subtitle, extensions: ["vtt"])

    // MARK: Archives
    static let zip = FileFormat(id: "zip", name: "ZIP", category: .archive, extensions: ["zip"])
    static let tar = FileFormat(id: "tar", name: "TAR", category: .archive, extensions: ["tar"])
    static let tgz = FileFormat(id: "tgz", name: "GZIP", category: .archive, extensions: ["tar.gz", "tgz"])
    static let gzip = FileFormat(id: "gz", name: "GZ", category: .archive, extensions: ["gz"])
    static let rar = FileFormat(id: "rar", name: "RAR", category: .archive, extensions: ["rar"])
    static let sevenZip = FileFormat(id: "7z", name: "7Z", category: .archive, extensions: ["7z"])
    static let tbz = FileFormat(id: "tbz", name: "TAR.BZ2", category: .archive, extensions: ["tar.bz2", "tbz2", "tbz"])
    static let txz = FileFormat(id: "txz", name: "TAR.XZ", category: .archive, extensions: ["tar.xz", "txz"])

    // MARK: Pseudo format
    static let folder = FileFormat(id: "folder", name: "Folder", category: .folder, extensions: [])

    static let all: [FileFormat] = [
        .jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .gif, .svg, .psd, .ico, .raw,
        .mp3, .m4a, .aac, .wav, .flac, .ogg, .opus, .aiff, .wma, .caf,
        .mp4, .mov, .mkv, .webm, .avi, .wmv, .flv, .mpeg, .mts, .threeGP,
        .pdf,
        .docx, .doc, .pages, .md, .txt, .rtf, .rtfd, .textClipping, .html, .odt,
        .epub,
        .pptx, .ppt, .key, .odp,
        .xlsx, .xls, .ods, .csv, .tsv, .numbers,
        .srt, .vtt,
        .zip, .tar, .tgz, .gzip, .rar, .sevenZip, .tbz, .txz,
    ]

    static func withID(_ id: String) -> FileFormat? {
        let key = id.lowercased()
        return all.first { $0.id == key } ?? FormatDetector.format(forExtension: key)
    }
}

/// Maps URLs, extensions and UTIs to `FileFormat`s.
public enum FormatDetector {
    private static let byExtension: [String: FileFormat] = {
        var map: [String: FileFormat] = [:]
        for format in FileFormat.all {
            for ext in format.extensions where map[ext] == nil { map[ext] = format }
        }
        return map
    }()

    private static let multiPartExtensions: [String] = FileFormat.all
        .flatMap(\.extensions)
        .filter { $0.contains(".") }
        .sorted { $0.count > $1.count }

    /// The extension that matched for `fileName` ("tar.gz" for "x.tar.gz"), if any.
    public static func matchedExtension(for fileName: String) -> String? {
        let lower = fileName.lowercased()
        for ext in multiPartExtensions where lower.hasSuffix("." + ext) { return ext }
        let ext = (lower as NSString).pathExtension
        return ext.isEmpty ? nil : ext
    }

    public static func format(forExtension ext: String) -> FileFormat? {
        byExtension[ext.lowercased()]
    }

    public static func format(for url: URL) -> FileFormat? {
        if let ext = matchedExtension(for: url.lastPathComponent), let format = byExtension[ext] {
            return format
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .folder
        }
        return nil
    }

    public static func format(forUTI identifier: String) -> FileFormat? {
        guard let type = UTType(identifier) else { return nil }
        if type.conforms(to: .folder) || type.conforms(to: .directory) { return .folder }
        if let ext = type.preferredFilenameExtension, let format = format(forExtension: ext) { return format }
        for tag in type.tags[.filenameExtension] ?? [] {
            if let format = format(forExtension: tag) { return format }
        }
        return nil
    }
}
