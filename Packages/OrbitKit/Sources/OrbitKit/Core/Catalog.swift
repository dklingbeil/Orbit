import Foundation

/// The files an operation will act on, with their detected formats.
public struct FileSelection: Sendable {
    public let urls: [URL]
    public let formats: [FileFormat?]

    public init(urls: [URL]) {
        self.urls = urls
        self.formats = urls.map(FormatDetector.format(for:))
    }

    /// For drags whose files don't exist yet (file promises), formats come from promised UTIs.
    public init(urls: [URL], formats: [FileFormat?]) {
        self.urls = urls
        self.formats = formats
    }

    public var count: Int { formats.count }
    public var knownFormats: [FileFormat] { formats.compactMap { $0 } }
    public var allKnown: Bool { !formats.isEmpty && formats.allSatisfy { $0 != nil } }

    public var uniformCategory: FormatCategory? {
        guard allKnown, let first = knownFormats.first?.category else { return nil }
        return knownFormats.allSatisfy { $0.category == first } ? first : nil
    }

    public var uniformFormat: FileFormat? {
        guard allKnown, let first = knownFormats.first else { return nil }
        return knownFormats.allSatisfy { $0 == first } ? first : nil
    }
}

/// Which conversions and tools exist for a selection.
public enum Catalog {
    // MARK: Conversions

    static let imageTargets: [FileFormat] = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .gif, .pdf]
    static let audioTargets: [FileFormat] = [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]
    static let videoTargets: [FileFormat] = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif]

    /// Targets in display order, possibly including the source format itself.
    static func rawTargets(for source: FileFormat) -> [FileFormat] {
        switch source.category {
        case .image: return source == .gif ? imageTargets + [.mp4, .webm, .mov] : imageTargets
        case .audio: return audioTargets
        case .video: return videoTargets + audioTargets
        case .pdf: return [.docx, .pages, .pptx, .xlsx, .jpg, .png, .epub, .txt, .md, .html]
        case .document: return [.docx, .pages, .pdf, .md, .txt, .epub, .html, .rtf]
        case .ebook: return [.docx, .pages, .pdf, .md, .txt, .html, .rtf]
        case .slides: return [.pdf, .jpg, .png, .pptx]
        case .spreadsheet: return [.xlsx, .ods, .csv, .tsv, .pdf]
        case .subtitle: return [.srt, .vtt, .txt]
        case .archive: return [.zip, .tar, .tgz]
        case .folder: return [.zip, .tar, .tgz]
        }
    }

    /// Formats `source` can be converted to (never itself).
    public static func targets(for source: FileFormat) -> [FileFormat] {
        rawTargets(for: source).filter { $0 != source }
    }

    /// Why a conversion can't run on this Mac, or `nil` if it can.
    public static func unavailableReason(from source: FileFormat, to target: FileFormat, capabilities caps: Capabilities) -> String? {
        let mediaSource = source.category == .audio || source.category == .video
        let gifToVideo = source == .gif && target.category == .video
        if (mediaSource || gifToVideo) && !caps.hasFFmpeg { return "Needs FFmpeg" }
        if target == .webp && caps.webpEncoder == nil { return "Needs a WebP encoder (FFmpeg with libwebp, or cwebp)" }
        if target == .avif && caps.avifEncoder == nil { return "Needs an AVIF encoder" }
        if target == .heic && !caps.canEncodeHEIC { return "This Mac can't encode HEIC" }
        if target == .pages && !caps.iwork.pages { return "Requires Pages" }
        switch source {
        case .pages where !caps.iwork.pages && caps.libreOffice == nil:
            return "Requires Pages or LibreOffice"
        case .key where !caps.iwork.keynote && caps.libreOffice == nil,
             .pptx where !caps.iwork.keynote && caps.libreOffice == nil,
             .ppt where !caps.iwork.keynote && caps.libreOffice == nil,
             .odp where caps.libreOffice == nil:
            return source == .odp ? "Requires LibreOffice" : "Requires Keynote or LibreOffice"
        case .xls where !caps.iwork.numbers && caps.libreOffice == nil,
             .numbers where !caps.iwork.numbers && caps.libreOffice == nil:
            return "Requires Numbers or LibreOffice"
        default:
            return nil
        }
    }

    public static func convertMenu(for selection: FileSelection, capabilities caps: Capabilities) -> [MenuNode] {
        guard selection.allKnown else { return [] }
        let formats = selection.knownFormats
        guard let first = formats.first else { return [] }

        let order = rawTargets(for: first)
        let candidates = order.filter { target in
            formats.allSatisfy { rawTargets(for: $0).contains(target) || $0 == target }
                && !formats.allSatisfy { $0 == target }
        }

        let groupAudio = formats.contains { $0.category == .video }
        var nodes: [MenuNode] = []
        var audioNodes: [MenuNode] = []
        for target in candidates {
            let reason = formats.lazy.compactMap { unavailableReason(from: $0, to: target, capabilities: caps) }.first
            let node = MenuNode(
                id: "convert.\(target.id)",
                title: target.name,
                detail: "Convert to \(target.name)",
                payload: .operation(.convert(target)),
                disabledReason: reason
            )
            if groupAudio && target.category == .audio { audioNodes.append(node) } else { nodes.append(node) }
        }
        if !audioNodes.isEmpty {
            nodes.append(MenuNode(id: "convert.audio", title: "Audio", detail: "Extract the audio track",
                                  symbol: "waveform", children: audioNodes))
        }
        return nodes
    }

    // MARK: Tools

    public static func toolsMenu(for selection: FileSelection, capabilities caps: Capabilities) -> [MenuNode] {
        var nodes: [MenuNode] = []
        let multiple = selection.count > 1
        let noFFmpeg = caps.hasFFmpeg ? nil : "Needs FFmpeg"

        switch selection.uniformCategory {
        case .image?:
            nodes = [
                tool(.imageCompress, "Compress", "Make the image smaller", "arrow.down.right.and.arrow.up.left", presets: [
                    ("light", "Light", "Compress lightly (high quality)"),
                    ("medium", "Medium", "Compress (balanced)"),
                    ("strong", "Strong", "Compress strongly (smallest file)"),
                ]),
                tool(.imageResize, "Resize", "Resize the image", "arrow.up.left.and.arrow.down.right", presets: [
                    ("75", "75%", "Resize to 75%"),
                    ("50", "50%", "Resize to 50%"),
                    ("25", "25%", "Resize to 25%"),
                    ("custom", "Custom…", "Resize to a custom size"),
                ]),
                tool(.imageCrop, "Crop", "Crop the image", "crop", requirement: multiple ? .none : .cropRect,
                     disabled: multiple ? "Crop works on one image at a time" : nil),
                tool(.imageRotate, "Rotate", "Rotate or flip", "rotate.right", presets: rotatePresets(flip: true)),
                tool(.imageRemoveBackground, "Cutout", "Remove the background", "wand.and.stars",
                     disabled: caps.canRemoveBackground ? nil : "Requires macOS 14"),
                tool(.imageStripMetadata, "Clean", "Remove location and camera metadata", "eye.slash"),
                tool(.imageExtractText, "Text", "Extract text (OCR)", "text.viewfinder"),
            ]
            if multiple {
                nodes.append(tool(.imagesToPDF, "Combine", "Combine into one PDF", "doc.on.doc"))
            }

        case .video?:
            nodes = [
                tool(.videoCompress, "Compress", "Make the video smaller", "arrow.down.right.and.arrow.up.left", presets: [
                    ("light", "Light", "Compress lightly"),
                    ("medium", "Medium", "Compress (balanced)"),
                    ("strong", "Strong", "Compress strongly (720p)"),
                ], disabled: noFFmpeg),
                tool(.videoTrim, "Trim", "Trim the video", "scissors", requirement: multiple ? .none : .trimRange,
                     disabled: noFFmpeg ?? (multiple ? "Trim works on one file at a time" : nil)),
                tool(.videoCrop, "Crop", "Crop the frame", "crop", requirement: multiple ? .none : .cropRect,
                     disabled: noFFmpeg ?? (multiple ? "Crop works on one file at a time" : nil)),
                tool(.videoRotate, "Rotate", "Rotate or flip", "rotate.right", presets: rotatePresets(flip: true), disabled: noFFmpeg),
                tool(.videoResize, "Resize", "Change the resolution", "arrow.up.left.and.arrow.down.right", presets: [
                    ("1080", "1080p", "Resize to 1080p"),
                    ("720", "720p", "Resize to 720p"),
                    ("480", "480p", "Resize to 480p"),
                ], disabled: noFFmpeg),
                tool(.videoMute, "Mute", "Remove the audio track", "speaker.slash", disabled: noFFmpeg),
                tool(.videoSpeed, "Speed", "Change playback speed", "speedometer", presets: speedPresets, disabled: noFFmpeg),
                tool(.videoSnapshot, "Frame", "Save a still frame", "camera", disabled: noFFmpeg),
                tool(.videoSplit, "Split", "Split into parts", "square.split.2x1", presets: splitPresets, disabled: noFFmpeg),
            ]
            if multiple { nodes.append(tool(.videoMerge, "Merge", "Join into one video", "rectangle.stack", disabled: noFFmpeg)) }

        case .audio?:
            nodes = [
                tool(.audioTrim, "Trim", "Trim the audio", "scissors", requirement: multiple ? .none : .trimRange,
                     disabled: noFFmpeg ?? (multiple ? "Trim works on one file at a time" : nil)),
                tool(.audioCompress, "Compress", "Make the file smaller", "arrow.down.right.and.arrow.up.left", presets: [
                    ("light", "Light", "Compress lightly (192 kbps)"),
                    ("medium", "Medium", "Compress (128 kbps)"),
                    ("strong", "Strong", "Compress strongly (64 kbps)"),
                ], disabled: noFFmpeg),
                tool(.audioNormalize, "Normalize", "Even out loudness", "waveform", disabled: noFFmpeg),
                tool(.audioSpeed, "Speed", "Change playback speed", "speedometer", presets: speedPresets, disabled: noFFmpeg),
                tool(.audioFade, "Fade", "Fade in and out", "waveform.path", presets: [
                    ("both", "In & Out", "Fade in and out"),
                    ("in", "In", "Fade in"),
                    ("out", "Out", "Fade out"),
                ], disabled: noFFmpeg),
                tool(.audioSplit, "Split", "Split into parts", "square.split.2x1", presets: splitPresets, disabled: noFFmpeg),
            ]
            if multiple { nodes.append(tool(.audioMerge, "Merge", "Join into one file", "rectangle.stack", disabled: noFFmpeg)) }

        case .pdf?:
            nodes = [
                tool(.pdfCompress, "Compress", "Make the PDF smaller", "arrow.down.right.and.arrow.up.left", presets: [
                    ("light", "Light", "Compress images lightly"),
                    ("strong", "Strong", "Compress and downsample images"),
                ]),
                tool(.pdfSplit, "Split", "Split into separate PDFs", "square.split.2x1", presets: [
                    ("pages", "Every Page", "One PDF per page"),
                    ("custom", "Ranges…", "Split by page ranges"),
                ]),
                tool(.pdfRotate, "Rotate", "Rotate all pages", "rotate.right", presets: rotatePresets(flip: false)),
                tool(.pdfOCR, "OCR", "Make text searchable", "text.magnifyingglass"),
                tool(.pdfProtect, "Protect", "Add a password", "lock",
                     requirement: .password(title: "Protect PDF", message: "Choose a password for the PDF.", confirm: true)),
                tool(.pdfUnlock, "Unlock", "Remove the password", "lock.open",
                     requirement: .password(title: "Unlock PDF", message: "Enter the PDF's current password.", confirm: false)),
            ]
            if multiple { nodes.append(tool(.pdfMerge, "Merge", "Merge into one PDF", "rectangle.stack")) }

        case .subtitle?:
            nodes = [
                tool(.subtitleShift, "Shift", "Shift subtitle timing", "clock", presets: [
                    ("1", "+1s", "Delay subtitles by 1 second"),
                    ("-1", "−1s", "Show subtitles 1 second earlier"),
                    ("0.5", "+0.5s", "Delay subtitles by half a second"),
                    ("-0.5", "−0.5s", "Show subtitles half a second earlier"),
                    ("custom", "Custom…", "Shift by a custom amount"),
                ]),
            ]

        case .archive?:
            nodes = [tool(.archiveExtract, "Extract", "Extract the archive", "archivebox")]

        default:
            break
        }

        // Mixed images + PDFs can still be combined into one PDF.
        if multiple, selection.allKnown, selection.uniformCategory == nil,
           selection.knownFormats.allSatisfy({ $0.category == .image || $0.category == .pdf }),
           selection.knownFormats.contains(where: { $0.category == .pdf }) {
            nodes.append(tool(.pdfMerge, "Merge", "Merge into one PDF", "rectangle.stack"))
        }

        nodes.append(tool(.compressZip, "ZIP", multiple ? "Compress into one ZIP" : "Compress to ZIP", "doc.zipper"))
        return nodes
    }

    // MARK: Helpers

    private static var speedPresets: [(String, String, String)] {
        [("0.5", "0.5×", "Half speed"), ("1.5", "1.5×", "1.5× speed"), ("2", "2×", "Double speed")]
    }

    private static var splitPresets: [(String, String, String)] {
        [
            ("half", "In Half", "Split into two halves"),
            ("60", "Every 1 min", "Split every minute"),
            ("300", "Every 5 min", "Split every 5 minutes"),
            ("custom", "Custom…", "Split at a custom interval"),
        ]
    }

    private static func rotatePresets(flip: Bool) -> [(String, String, String)] {
        var presets = [
            ("right", "Right", "Rotate 90° clockwise"),
            ("left", "Left", "Rotate 90° counter-clockwise"),
            ("180", "180°", "Rotate 180°"),
        ]
        if flip {
            presets += [("flipH", "Flip H", "Flip horizontally"), ("flipV", "Flip V", "Flip vertically")]
        }
        return presets
    }

    /// Requirement for presets that ask for a value.
    static func requirement(for id: ToolID, option: String) -> InputRequirement {
        guard option == "custom" else { return .none }
        switch id {
        case .imageResize:
            return .text(title: "Resize Image", message: "Enter a percentage (40%), a size (1920x1080), a width (1200w) or a height (800h).",
                         placeholder: "1920x1080", initial: "")
        case .videoSplit, .audioSplit:
            return .text(title: "Split Into Parts", message: "Split every… (for example 30s, 2m or 1:30).",
                         placeholder: "2m", initial: "")
        case .pdfSplit:
            return .text(title: "Split PDF", message: "Enter page ranges separated by commas. Each range becomes its own PDF.",
                         placeholder: "1-3, 4, 5-8", initial: "")
        case .subtitleShift:
            return .text(title: "Shift Subtitles", message: "Seconds to shift by. Use a negative number to show subtitles earlier.",
                         placeholder: "1.5", initial: "")
        default:
            return .none
        }
    }

    private static func tool(
        _ id: ToolID, _ title: String, _ detail: String, _ symbol: String,
        presets: [(String, String, String)] = [],
        requirement: InputRequirement = .none,
        disabled: String? = nil
    ) -> MenuNode {
        if presets.isEmpty {
            return MenuNode(id: "tool.\(id.rawValue)", title: title, detail: detail, symbol: symbol,
                            payload: .operation(.tool(id)), requirement: requirement, disabledReason: disabled)
        }
        let children = presets.map { option, childTitle, childDetail in
            MenuNode(id: "tool.\(id.rawValue).\(option)", title: childTitle, detail: childDetail,
                     payload: .operation(.tool(id, option)), requirement: self.requirement(for: id, option: option),
                     disabledReason: disabled)
        }
        return MenuNode(id: "tool.\(id.rawValue)", title: title, detail: detail, symbol: symbol,
                        children: children, disabledReason: disabled)
    }
}
