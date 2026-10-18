import Foundation

/// Video and audio tools (compress, trim, crop, rotate, speed, split, merge…).
enum MediaTools {
    // MARK: Video

    static func video(_ tool: ToolID, option: String?, inputs: [URL], context: JobContext) async throws -> [URL] {
        let ffmpeg = try context.ffmpeg
        if tool == .videoMerge { return [try await mergeVideos(inputs, ffmpeg: ffmpeg, context: context)] }

        var outputs: [URL] = []
        for input in inputs {
            try Task.checkCancellation()
            let source = FormatDetector.format(for: input) ?? .mp4
            let base = OutputNaming.baseName(of: input)
            let info = try await ffmpeg.probe(input)
            guard info.hasVideo else { throw OrbitError.invalidInput("\(input.lastPathComponent) has no video track.") }
            let container = MediaCodecs.toolContainer(for: source)
            let encode = { (quality: VideoQuality) in
                MediaCodecs.encodeArgs(container: container, ffmpeg: ffmpeg, settings: context.settings, quality: quality, hasAudio: info.hasAudio)
            }
            let maps = ["-map", "0:v:0", "-map", "0:a:0?"]
            var duration = info.duration

            let suffix: String
            var ext = container.fileExtension
            var args: [String]

            switch tool {
            case .videoCompress:
                let quality: VideoQuality = option == "light" ? .light : option == "strong" ? .strong : .medium
                var filter = MediaCodecs.evenDimensions
                if quality == .strong {
                    filter = "scale='if(gt(iw,ih),-2,min(720,iw))':'if(gt(iw,ih),min(720,ih),-2)'"
                }
                suffix = "compressed"
                args = ["-i", input.path] + maps + ["-vf", filter] + encode(quality)

            case .videoTrim:
                let (start, end) = try trimRange(context.parameters, duration: info.duration)
                duration = end - start
                suffix = "trimmed"
                args = ["-ss", seconds(start), "-i", input.path, "-t", seconds(end - start)] + maps
                    + ["-vf", MediaCodecs.evenDimensions] + encode(.standard)

            case .videoCrop:
                guard let rect = context.parameters.cropRect else { throw OrbitError.invalidInput("No crop area was chosen.") }
                let w = max(2, Int(rect.width) / 2 * 2), h = max(2, Int(rect.height) / 2 * 2)
                suffix = "cropped"
                args = ["-i", input.path] + maps + ["-vf", "crop=\(w):\(h):\(Int(rect.minX)):\(Int(rect.minY))"] + encode(.standard)

            case .videoRotate:
                let filter: String
                switch option ?? "right" {
                case "left": filter = "transpose=2"
                case "180": filter = "transpose=1,transpose=1"
                case "flipH": filter = "hflip"
                case "flipV": filter = "vflip"
                default: filter = "transpose=1"
                }
                suffix = option == "flipH" || option == "flipV" ? "flipped" : "rotated"
                args = ["-i", input.path] + maps + ["-vf", filter + "," + MediaCodecs.evenDimensions] + encode(.standard)

            case .videoResize:
                let target = Int(option ?? "720") ?? 720
                let filter = "scale='if(gt(iw,ih),-2,min(\(target),iw))':'if(gt(iw,ih),min(\(target),ih),-2)'"
                suffix = "\(target)p"
                args = ["-i", input.path] + maps + ["-vf", filter] + encode(.standard)

            case .videoMute:
                suffix = "muted"
                args = ["-i", input.path, "-map", "0:v:0", "-c:v", "copy", "-an"]
                if container == .mp4 || container == .mov { args += ["-movflags", "+faststart"] }

            case .videoSpeed:
                let factor = Double(option ?? "2") ?? 2
                duration = info.duration.map { $0 / factor }
                suffix = "\(formatFactor(factor))x"
                args = ["-i", input.path] + maps + ["-vf", "setpts=PTS/\(factor)," + MediaCodecs.evenDimensions]
                if info.hasAudio { args += ["-af", atempoChain(factor)] }
                args += encode(.standard)

            case .videoSnapshot:
                let at = (info.duration ?? 0) / 2
                suffix = "frame"
                ext = "png"
                duration = nil
                args = ["-ss", seconds(at), "-i", input.path, "-frames:v", "1", "-update", "1"]

            case .videoSplit:
                outputs += try await split(input, info: info, option: option, ext: container.fileExtension,
                                           streams: ["-map", "0:v:0", "-map", "0:a:0?"], reencode: encode(.standard),
                                           ffmpeg: ffmpeg, context: context)
                continue

            default:
                throw OrbitError.unsupported(tool.rawValue)
            }

            let output = context.output(base: "\(base)-\(suffix)", ext: ext)
            try await ffmpeg.run(args + [output.path], duration: duration, progress: context.progress)
            outputs.append(output)
        }
        return outputs
    }

    private static func mergeVideos(_ inputs: [URL], ffmpeg: FFmpeg, context: JobContext) async throws -> URL {
        guard inputs.count >= 2 else { throw OrbitError.invalidInput("Choose at least two videos to merge.") }
        let sorted = inputs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var infos: [MediaInfo] = []
        for input in sorted { infos.append(try await ffmpeg.probe(input)) }
        guard let first = infos.first, let w0 = first.width, let h0 = first.height else {
            throw OrbitError.invalidInput("Couldn't read the first video's size.")
        }
        let width = w0 / 2 * 2, height = h0 / 2 * 2
        let fps = min(60, max(1, (first.fps ?? 30).rounded()))
        let anyAudio = infos.contains(where: \.hasAudio)

        var args: [String] = []
        for input in sorted { args += ["-i", input.path] }
        var extraIndex = sorted.count
        var filters: [String] = []
        var concatInputs = ""
        for (index, info) in infos.enumerated() {
            filters.append("[\(index):v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(Int(fps)),format=yuv420p[v\(index)]")
            concatInputs += "[v\(index)]"
            if anyAudio {
                if info.hasAudio {
                    filters.append("[\(index):a:0]aformat=sample_rates=48000:channel_layouts=stereo[a\(index)]")
                    concatInputs += "[a\(index)]"
                } else {
                    args += ["-f", "lavfi", "-t", seconds(info.duration ?? 1), "-i", "anullsrc=r=48000:cl=stereo"]
                    filters.append("[\(extraIndex):a]aformat=sample_rates=48000:channel_layouts=stereo[a\(index)]")
                    concatInputs += "[a\(index)]"
                    extraIndex += 1
                }
            }
        }
        filters.append("\(concatInputs)concat=n=\(sorted.count):v=1:a=\(anyAudio ? 1 : 0)[outv]\(anyAudio ? "[outa]" : "")")
        args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[outv]"]
        if anyAudio { args += ["-map", "[outa]"] }
        args += MediaCodecs.encodeArgs(container: .mp4, ffmpeg: ffmpeg, settings: context.settings, hasAudio: anyAudio)

        let base = OutputNaming.baseName(of: sorted[0])
        let output = context.output(base: "\(base)-merged", ext: "mp4")
        let total = infos.compactMap(\.duration).reduce(0, +)
        try await ffmpeg.run(args + [output.path], duration: total, progress: context.progress)
        return output
    }

    // MARK: Audio

    static func audio(_ tool: ToolID, option: String?, inputs: [URL], context: JobContext) async throws -> [URL] {
        let ffmpeg = try context.ffmpeg
        if tool == .audioMerge { return [try await mergeAudio(inputs, ffmpeg: ffmpeg, context: context)] }

        var outputs: [URL] = []
        for input in inputs {
            try Task.checkCancellation()
            let source = FormatDetector.format(for: input) ?? .m4a
            let base = OutputNaming.baseName(of: input)
            let info = try await ffmpeg.probe(input)
            guard info.hasAudio else { throw OrbitError.invalidInput("\(input.lastPathComponent) has no audio track.") }
            var format = MediaCodecs.toolAudioFormat(for: source)
            var duration = info.duration
            let suffix: String
            var preArgs: [String] = []
            var filters: [String] = []
            var bitrate: String?

            switch tool {
            case .audioTrim:
                let (start, end) = try trimRange(context.parameters, duration: info.duration)
                duration = end - start
                preArgs = ["-ss", seconds(start)]
                suffix = "trimmed"
                bitrate = MediaCodecs.lossyAudio.contains(format) ? "256k" : nil
                if format == .mp3 { bitrate = nil }
                outputs.append(try await runAudio(input, preArgs: preArgs, postInput: ["-t", seconds(end - start)], filters: filters,
                                                  format: format, bitrate: bitrate, base: base, suffix: suffix, info: info,
                                                  duration: duration, ffmpeg: ffmpeg, context: context))
                continue

            case .audioCompress:
                bitrate = option == "light" ? "192k" : option == "strong" ? "64k" : "128k"
                if !MediaCodecs.lossyAudio.contains(format) { format = .m4a }
                suffix = "compressed"

            case .audioNormalize:
                filters.append("loudnorm=I=-16:TP=-1.5:LRA=11")
                suffix = "normalized"
                bitrate = MediaCodecs.lossyAudio.contains(format) ? "256k" : nil

            case .audioSpeed:
                let factor = Double(option ?? "1.5") ?? 1.5
                filters.append(atempoChain(factor))
                duration = info.duration.map { $0 / factor }
                suffix = "\(formatFactor(factor))x"
                bitrate = MediaCodecs.lossyAudio.contains(format) ? "256k" : nil

            case .audioFade:
                let total = info.duration ?? 0
                let length = max(0.5, min(3, total / 4))
                if option != "out" { filters.append("afade=t=in:st=0:d=\(seconds(length))") }
                if option != "in", total > 0 { filters.append("afade=t=out:st=\(seconds(total - length)):d=\(seconds(length))") }
                suffix = "faded"
                bitrate = MediaCodecs.lossyAudio.contains(format) ? "256k" : nil

            case .audioSplit:
                var reencode = try MediaCodecs.audioArgs(for: format, info: info, ffmpeg: ffmpeg,
                                                         bitrate: MediaCodecs.lossyAudio.contains(format) && format != .mp3 ? "256k" : nil)
                if reencode.contains("copy") { reencode = try MediaCodecs.audioArgs(for: format, info: info, ffmpeg: ffmpeg, bitrate: "256k") }
                outputs += try await split(input, info: info, option: option, ext: format.fileExtension,
                                           streams: ["-map", "0:a:0"], reencode: reencode, ffmpeg: ffmpeg, context: context)
                continue

            default:
                throw OrbitError.unsupported(tool.rawValue)
            }

            if format == .mp3, bitrate == "256k" { bitrate = nil }
            outputs.append(try await runAudio(input, preArgs: preArgs, postInput: [], filters: filters, format: format, bitrate: bitrate,
                                              base: base, suffix: suffix, info: info, duration: duration, ffmpeg: ffmpeg, context: context))
        }
        return outputs
    }

    private static func runAudio(_ input: URL, preArgs: [String], postInput: [String], filters: [String], format: FileFormat,
                                 bitrate: String?, base: String, suffix: String, info: MediaInfo, duration: Double?,
                                 ffmpeg: FFmpeg, context: JobContext) async throws -> URL {
        var codec = try MediaCodecs.audioArgs(for: format, info: info, ffmpeg: ffmpeg, bitrate: bitrate)
        if codec.contains("copy") { codec = try MediaCodecs.audioArgs(for: format, info: info, ffmpeg: ffmpeg, bitrate: "256k") }
        var args = preArgs + ["-i", input.path] + postInput + ["-map", "0:a:0", "-vn", "-map_metadata", "0"]
        if !filters.isEmpty { args += ["-af", filters.joined(separator: ",")] }
        if let rate = info.sampleRate, format != .opus { args += ["-ar", "\(rate)"] }
        let output = context.output(base: "\(base)-\(suffix)", ext: format.fileExtension)
        try await ffmpeg.run(args + codec + [output.path], duration: duration, progress: context.progress)
        return output
    }

    private static func mergeAudio(_ inputs: [URL], ffmpeg: FFmpeg, context: JobContext) async throws -> URL {
        guard inputs.count >= 2 else { throw OrbitError.invalidInput("Choose at least two audio files to merge.") }
        let sorted = inputs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var infos: [MediaInfo] = []
        for input in sorted { infos.append(try await ffmpeg.probe(input)) }
        let format = MediaCodecs.toolAudioFormat(for: FormatDetector.format(for: sorted[0]) ?? .m4a)

        var args: [String] = []
        for input in sorted { args += ["-i", input.path] }
        var filters: [String] = []
        var concatInputs = ""
        for index in sorted.indices {
            filters.append("[\(index):a:0]aformat=sample_rates=48000:channel_layouts=stereo[a\(index)]")
            concatInputs += "[a\(index)]"
        }
        filters.append("\(concatInputs)concat=n=\(sorted.count):v=0:a=1[outa]")
        args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[outa]"]
        var codec = try MediaCodecs.audioArgs(for: format, info: MediaInfo(), ffmpeg: ffmpeg,
                                              bitrate: MediaCodecs.lossyAudio.contains(format) && format != .mp3 ? "256k" : nil)
        if codec.contains("copy") { codec = try MediaCodecs.audioArgs(for: format, info: MediaInfo(), ffmpeg: ffmpeg, bitrate: "256k") }
        let output = context.output(base: "\(OutputNaming.baseName(of: sorted[0]))-merged", ext: format.fileExtension)
        let total = infos.compactMap(\.duration).reduce(0, +)
        try await ffmpeg.run(args + codec + [output.path], duration: total, progress: context.progress)
        return output
    }

    // MARK: Shared

    /// Splits by stream copy (instant). If keyframes are too sparse to honor the interval,
    /// falls back to re-encoding each part with `reencode` codec arguments.
    private static func split(_ input: URL, info: MediaInfo, option: String?, ext: String, streams: [String], reencode: [String],
                              ffmpeg: FFmpeg, context: JobContext) async throws -> [URL] {
        let total = info.duration ?? 0
        let interval: Double
        switch option ?? "half" {
        case "half":
            guard total > 1 else { throw OrbitError.invalidInput("The file is too short to split.") }
            interval = total / 2 + 0.05
        case "custom":
            guard let text = context.parameters.text, let parsed = Timecode.parseDuration(text), parsed > 0 else {
                throw OrbitError.invalidInput("Enter an interval such as 30s, 2m or 1:30.")
            }
            interval = parsed
        default:
            interval = Double(option ?? "") ?? 60
        }
        if total > 0, interval >= total {
            throw OrbitError.invalidInput("The file is shorter than the split interval.")
        }
        let base = OutputNaming.baseName(of: input)
        let folder = try context.outputFolder(named: "\(base) parts")
        let pattern = folder.appendingPathComponent("\(base)-part%02d.\(ext)").path
        let args = ["-i", input.path] + streams + ["-c", "copy", "-f", "segment", "-segment_time", seconds(interval),
                                                   "-reset_timestamps", "1", "-segment_start_number", "1", pattern]
        try await ffmpeg.run(args, duration: info.duration, progress: { value in context.progress(value.map { $0 * 0.3 }) })

        let partLength = option == "half" || option == nil ? total / 2 : interval
        let expected = total > 0 ? Int((total / partLength).rounded(.up)) : 0
        let produced = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0
        if produced < expected, expected <= 100 {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            for part in 0..<expected {
                try Task.checkCancellation()
                let start = Double(part) * partLength
                let length = min(partLength, total - start)
                guard length > 0.05 else { continue }
                let url = folder.appendingPathComponent(String(format: "\(base)-part%02d.\(ext)", part + 1))
                try await ffmpeg.run(["-ss", seconds(start), "-i", input.path, "-t", seconds(length)] + streams + reencode + [url.path],
                                     duration: length) { value in
                    context.progress(value.map { 0.3 + 0.7 * (Double(part) + $0) / Double(expected) })
                }
            }
        }
        return [folder]
    }

    static func trimRange(_ parameters: OperationParameters, duration: Double?) throws -> (Double, Double) {
        let start = max(0, parameters.trimStart ?? 0)
        let end = parameters.trimEnd ?? duration ?? 0
        guard end > start else { throw OrbitError.invalidInput("The trim range is empty.") }
        return (start, end)
    }

    /// atempo accepts 0.5…100 per filter; chain for anything slower.
    static func atempoChain(_ factor: Double) -> String {
        var remaining = factor
        var parts: [String] = []
        while remaining < 0.5 {
            parts.append("atempo=0.5")
            remaining /= 0.5
        }
        parts.append("atempo=\(remaining)")
        return parts.joined(separator: ",")
    }

    static func seconds(_ value: Double) -> String { String(format: "%.3f", value) }

    private static func formatFactor(_ factor: Double) -> String {
        factor == factor.rounded() ? String(Int(factor)) : String(factor)
    }
}

/// Parsing for "1:30", "90", "2m", "1h20m", "00:01:02.500".
public enum Timecode {
    public static func parseDuration(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        if s.contains(":") {
            let parts = s.split(separator: ":").map { Double($0.replacingOccurrences(of: ",", with: ".")) }
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        }
        if let plain = Double(s) { return plain }
        var total = 0.0
        var number = ""
        for char in s {
            if char.isNumber || char == "." { number.append(char); continue }
            guard let value = Double(number) else { if char == " " { continue }; return nil }
            switch char {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            case " ": continue
            default: return nil
            }
            number = ""
        }
        if !number.isEmpty { total += Double(number) ?? 0 }
        return total
    }

    public static func format(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        let h = ms / 3_600_000, m = (ms / 60_000) % 60, s = (ms / 1000) % 60, f = ms % 1000
        return h > 0 ? String(format: "%d:%02d:%02d.%03d", h, m, s, f) : String(format: "%d:%02d.%03d", m, s, f)
    }
}
