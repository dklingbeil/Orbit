import Foundation

/// Tunables the host app exposes in Settings.
public struct EngineSettings: Sendable {
    /// 0…1 quality for lossy image encoders.
    public var imageQuality: Double = 0.85
    /// Resolution used when rendering PDF pages to images.
    public var pdfRenderDPI: Double = 300
    /// Use VideoToolbox (fast, hardware) instead of x264 (smaller, slower) when re-encoding video.
    public var preferHardwareVideo: Bool = true
    /// Keep EXIF/GPS and similar metadata when converting images.
    public var preserveImageMetadata: Bool = true

    public init() {}
}

/// Everything an operation needs while it runs.
public struct JobContext: Sendable {
    /// Scratch directory that receives the outputs. The caller moves them into place afterwards.
    public let workDirectory: URL
    public let capabilities: Capabilities
    public let settings: EngineSettings
    public let parameters: OperationParameters
    public let progress: @Sendable (Double?) -> Void

    public init(workDirectory: URL, capabilities: Capabilities, settings: EngineSettings,
                parameters: OperationParameters = OperationParameters(), progress: @escaping @Sendable (Double?) -> Void = { _ in }) {
        self.workDirectory = workDirectory
        self.capabilities = capabilities
        self.settings = settings
        self.parameters = parameters
        self.progress = progress
    }

    /// `workDirectory/<base>.<ext>` (unique within the work directory).
    public func output(base: String, ext: String) -> URL {
        OutputNaming.uniqueURL(in: workDirectory, fileName: OutputNaming.fileName(base: base, ext: ext))
    }

    /// A subdirectory for multi-file results (e.g. every page of a PDF).
    public func outputFolder(named name: String) throws -> URL {
        let url = OutputNaming.uniqueURL(in: workDirectory, fileName: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Private scratch space that is not part of the output.
    public func scratch(_ name: String = UUID().uuidString) throws -> URL {
        let url = workDirectory.appendingPathComponent(".scratch", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public var ffmpeg: FFmpeg {
        get throws {
            guard let ffmpeg = capabilities.ffmpeg else {
                throw OrbitError.missingTool("FFmpeg isn't available. Install it with `brew install ffmpeg` or use a build of Orbit that bundles it.")
            }
            return ffmpeg
        }
    }
}

/// Runs an `OperationSpec` against input files. Pure engine: no UI, no final placement.
public enum OperationRunner {
    /// Runs `spec` on `inputs` and returns the produced files (inside `context.workDirectory`).
    /// Per-file operations should be called once per input; combined tools receive the whole selection.
    public static func run(_ spec: OperationSpec, inputs: [URL], context: JobContext) async throws -> [URL] {
        guard !inputs.isEmpty else { throw OrbitError.invalidInput("No files to process.") }
        let produced: [URL]
        switch spec.kind {
        case .convert(let target):
            var results: [URL] = []
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                let scaled = JobContext(workDirectory: context.workDirectory, capabilities: context.capabilities,
                                        settings: context.settings, parameters: context.parameters) { value in
                    let base = Double(index) / Double(inputs.count)
                    context.progress(value.map { base + $0 / Double(inputs.count) })
                }
                results += try await Converter.convert(input, to: target, context: scaled)
            }
            produced = results
        case .tool(let tool):
            produced = try await Tools.run(tool, option: spec.option, inputs: inputs, context: context)
        }
        try? FileManager.default.removeItem(at: context.workDirectory.appendingPathComponent(".scratch"))
        guard !produced.isEmpty else { throw OrbitError.failed("Nothing was produced.") }
        return produced
    }
}

/// Routes a single conversion to the right engine.
public enum Converter {
    public static func convert(_ input: URL, to target: FileFormat, context: JobContext) async throws -> [URL] {
        guard let source = FormatDetector.format(for: input) else {
            throw OrbitError.unsupported("\(input.lastPathComponent) has an unknown format")
        }
        if source == target { return [] }
        if let reason = Catalog.unavailableReason(from: source, to: target, capabilities: context.capabilities) {
            throw OrbitError.missingTool(reason)
        }
        let base = OutputNaming.baseName(of: input)

        switch (source.category, target.category) {
        case (.image, .image), (.image, .pdf):
            return [try await ImageConverter.convert(input, from: source, to: target, base: base, context: context)]
        case (.image, .video):
            return [try await MediaConverter.convert(input, to: target, base: base, context: context)]
        case (.audio, .audio), (.video, .video), (.video, .audio), (.video, .image):
            return [try await MediaConverter.convert(input, to: target, base: base, context: context)]
        case (.pdf, .image):
            return try PDFRenderer.renderPages(of: input, as: target, base: base, context: context)
        case (.pdf, .slides):
            return [try PDFToPPTX.convert(input, base: base, context: context)]
        case (.pdf, .spreadsheet):
            return [try PDFTableExtractor.convert(input, to: target, base: base, context: context)]
        case (.pdf, .document), (.pdf, .ebook),
             (.document, .document), (.document, .ebook), (.document, .pdf),
             (.ebook, .document), (.ebook, .pdf):
            return [try await DocumentConverter.convert(input, from: source, to: target, base: base, context: context)]
        case (.slides, _):
            return try await SlidesConverter.convert(input, from: source, to: target, base: base, context: context)
        case (.spreadsheet, _):
            return try await SpreadsheetConverter.convert(input, from: source, to: target, base: base, context: context)
        case (.subtitle, _):
            return [try SubtitleConverter.convert(input, from: source, to: target, base: base, context: context)]
        case (.archive, .archive), (.folder, .archive):
            return [try await ArchiveEngine.convert(input, from: source, to: target, base: base, context: context)]
        default:
            throw OrbitError.unsupported("\(source.name) → \(target.name)")
        }
    }
}
