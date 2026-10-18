import Foundation

/// Facts about a media file, parsed from `ffmpeg -i` output.
public struct MediaInfo: Sendable, Equatable {
    public var duration: Double?
    public var videoCodec: String?
    public var audioCodec: String?
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var audioChannels: Int?
    public var sampleRate: Int?

    public var hasVideo: Bool { videoCodec != nil }
    public var hasAudio: Bool { audioCodec != nil }

    public init() {}

    /// Parses the stream summary ffmpeg prints to stderr.
    public static func parse(_ text: String) -> MediaInfo {
        var info = MediaInfo()
        if let match = text.firstMatch(of: #/Duration: (\d+):(\d+):(\d+(?:\.\d+)?)/#) {
            let h = Double(match.1) ?? 0, m = Double(match.2) ?? 0, s = Double(match.3) ?? 0
            info.duration = h * 3600 + m * 60 + s
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let line = String(line)
            guard line.contains("Stream #") else { continue }
            if info.videoCodec == nil, !line.contains("attached pic"),
               let match = line.firstMatch(of: #/Video: ([A-Za-z0-9_]+)/#) {
                info.videoCodec = String(match.1)
                if let size = line.firstMatch(of: #/[ ,](\d{2,5})x(\d{2,5})[ ,\]]/#) {
                    info.width = Int(size.1)
                    info.height = Int(size.2)
                }
                if let fps = line.firstMatch(of: #/(\d+(?:\.\d+)?) fps/#) {
                    info.fps = Double(fps.1)
                } else if let tbr = line.firstMatch(of: #/(\d+(?:\.\d+)?) tbr/#) {
                    info.fps = Double(tbr.1)
                }
            }
            if info.audioCodec == nil, let match = line.firstMatch(of: #/Audio: ([A-Za-z0-9_]+)/#) {
                info.audioCodec = String(match.1)
                if let rate = line.firstMatch(of: #/(\d{4,6}) Hz/#) { info.sampleRate = Int(rate.1) }
                if line.contains(" mono") { info.audioChannels = 1 }
                else if line.contains(" stereo") { info.audioChannels = 2 }
                else if line.contains("5.1") { info.audioChannels = 6 }
            }
        }
        return info
    }
}

/// Thin wrapper around an `ffmpeg` executable (bundled with the app or installed by the user).
public final class FFmpeg: @unchecked Sendable {
    public let url: URL
    public let encoders: Set<String>
    public let version: String

    public init(url: URL) {
        self.url = url
        let (encoders, version) = FFmpeg.inspect(url)
        self.encoders = encoders
        self.version = version
    }

    public func has(_ encoder: String) -> Bool { encoders.contains(encoder) }

    /// Searches, in order: an explicit override, the app bundle, Homebrew/MacPorts, and PATH.
    public static func locate(override: String? = nil) -> FFmpeg? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let override, !override.isEmpty { candidates.append(URL(fileURLWithPath: override)) }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg") { candidates.append(bundled) }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("bin/ffmpeg"))
        }
        if let found = ProcessRunner.which("ffmpeg") { candidates.append(found) }
        for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
            return FFmpeg(url: candidate)
        }
        return nil
    }

    private static func inspect(_ url: URL) -> (Set<String>, String) {
        let process = Process()
        process.executableURL = url
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var encoders = Set<String>()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, parts[0].count == 6, parts[0].first.map({ "VAS".contains($0) }) == true else { continue }
                encoders.insert(String(parts[1]))
            }
        } catch {
            return ([], "unknown")
        }

        let versionProcess = Process()
        versionProcess.executableURL = url
        versionProcess.arguments = ["-version"]
        let versionPipe = Pipe()
        versionProcess.standardOutput = versionPipe
        versionProcess.standardError = FileHandle.nullDevice
        var version = "unknown"
        if (try? versionProcess.run()) != nil {
            let data = versionPipe.fileHandleForReading.readDataToEndOfFile()
            versionProcess.waitUntilExit()
            let first = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first ?? ""
            if let match = first.firstMatch(of: #/ffmpeg version (\S+)/#) { version = String(match.1) }
        }
        return (encoders, version)
    }

    public func probe(_ input: URL) async throws -> MediaInfo {
        let result = try await ProcessRunner.run(url, ["-hide_banner", "-nostdin", "-i", input.path])
        let info = MediaInfo.parse(result.stderrString)
        if !info.hasAudio && !info.hasVideo {
            throw OrbitError.invalidInput("FFmpeg could not read \(input.lastPathComponent).")
        }
        return info
    }

    /// Runs ffmpeg with progress reporting. `duration` is the expected output length in seconds.
    /// If a hardware (VideoToolbox) encode fails — as it does in virtual machines — it is retried in software.
    public func run(
        _ arguments: [String],
        duration: Double?,
        progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws {
        do {
            try await runOnce(arguments, duration: duration, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let fallback = softwareFallback(for: arguments) else { throw error }
            try await runOnce(fallback, duration: duration, progress: progress)
        }
    }

    /// Swaps a VideoToolbox encoder for x264 (or MPEG-4 if x264 isn't available).
    func softwareFallback(for arguments: [String]) -> [String]? {
        guard let index = arguments.firstIndex(where: { $0 == "h264_videotoolbox" || $0 == "hevc_videotoolbox" }),
              index > 0, arguments[index - 1] == "-c:v" else { return nil }
        var replaced = arguments
        var end = index
        var crf = 23
        if index + 2 < arguments.count, arguments[index + 1] == "-q:v", let q = Int(arguments[index + 2]) {
            crf = [65: 20, 55: 23, 45: 27, 38: 30][q] ?? 23
            end = index + 2
        }
        let software = has("libx264") ? ["libx264", "-crf", "\(crf)", "-preset", "medium"] : ["mpeg4", "-q:v", "4"]
        replaced.replaceSubrange(index...end, with: software)
        return replaced
    }

    private func runOnce(
        _ arguments: [String],
        duration: Double?,
        progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws {
        let args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + arguments
        let total = duration ?? 0
        let result = try await ProcessRunner.run(url, args, onStdoutLine: { line in
            guard total > 0, let progress else { return }
            if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                let value = Double(line.split(separator: "=").last ?? "") ?? 0
                progress(min(1, max(0, value / 1_000_000 / total)))
            }
        })
        guard result.status == 0 else {
            throw OrbitError.failed("FFmpeg failed: \(ProcessRunner.summarizeError(result.stderrString))")
        }
    }
}
