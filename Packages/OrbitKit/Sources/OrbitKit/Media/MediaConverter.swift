import Foundation

/// Encoder quality tiers shared by conversions and the Compress tool.
enum VideoQuality {
    case standard, light, medium, strong

    var videoToolboxQ: Int {
        switch self { case .standard: return 65; case .light: return 55; case .medium: return 45; case .strong: return 38 }
    }
    var x264CRF: Int {
        switch self { case .standard: return 20; case .light: return 23; case .medium: return 27; case .strong: return 30 }
    }
    var vp9CRF: Int {
        switch self { case .standard: return 32; case .light: return 35; case .medium: return 38; case .strong: return 42 }
    }
    var mpeg4Q: Int {
        switch self { case .standard: return 3; case .light: return 4; case .medium: return 6; case .strong: return 8 }
    }
    var audioBitrate: String {
        switch self { case .standard: return "192k"; case .light: return "160k"; case .medium: return "128k"; case .strong: return "96k" }
    }
}

/// Builds ffmpeg codec arguments per container.
enum MediaCodecs {
    static let lossyAudio: Set<FileFormat> = [.mp3, .m4a, .aac, .ogg, .opus, .wma]

    /// Codec arguments for an audio-only output. `bitrate` overrides the format's default quality.
    static func audioArgs(for target: FileFormat, info: MediaInfo, ffmpeg: FFmpeg, bitrate: String? = nil) throws -> [String] {
        let aac = ffmpeg.has("aac_at") ? "aac_at" : "aac"
        switch target {
        case .mp3:
            guard ffmpeg.has("libmp3lame") else { throw OrbitError.missingTool("This FFmpeg build has no MP3 encoder (libmp3lame).") }
            return ["-c:a", "libmp3lame"] + (bitrate.map { ["-b:a", $0] } ?? ["-q:a", "2"]) + ["-id3v2_version", "3"]
        case .m4a, .aac:
            if bitrate == nil, info.audioCodec == "aac" { return ["-c:a", "copy"] }
            return ["-c:a", aac, "-b:a", bitrate ?? "256k"]
        case .wav:
            return ["-c:a", "pcm_s16le"]
        case .aiff:
            return ["-c:a", "pcm_s16be"]
        case .flac:
            return ["-c:a", "flac"]
        case .caf:
            return ["-c:a", "alac"]
        case .ogg:
            if ffmpeg.has("libvorbis") { return ["-c:a", "libvorbis"] + (bitrate.map { ["-b:a", $0] } ?? ["-q:a", "6"]) }
            if ffmpeg.has("libopus") { return ["-c:a", "libopus", "-b:a", bitrate ?? "160k", "-ar", "48000"] }
            return ["-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-b:a", bitrate ?? "192k"]
        case .opus:
            guard ffmpeg.has("libopus") else { throw OrbitError.missingTool("This FFmpeg build has no Opus encoder (libopus).") }
            return ["-c:a", "libopus", "-b:a", bitrate ?? "160k", "-ar", "48000"]
        case .wma:
            return ["-c:a", "wmav2", "-b:a", bitrate ?? "192k"]
        default:
            throw OrbitError.unsupported("audio output \(target.name)")
        }
    }

    private static func h264Args(ffmpeg: FFmpeg, settings: EngineSettings, quality: VideoQuality) -> [String] {
        let hardware = ffmpeg.has("h264_videotoolbox") && (settings.preferHardwareVideo || !ffmpeg.has("libx264"))
        if hardware {
            return ["-c:v", "h264_videotoolbox", "-q:v", "\(quality.videoToolboxQ)", "-pix_fmt", "yuv420p"]
        }
        if ffmpeg.has("libx264") {
            return ["-c:v", "libx264", "-crf", "\(quality.x264CRF)", "-preset", "medium", "-pix_fmt", "yuv420p"]
        }
        return ["-c:v", "mpeg4", "-q:v", "\(quality.mpeg4Q)", "-pix_fmt", "yuv420p"]
    }

    private static func aacArgs(ffmpeg: FFmpeg, bitrate: String) -> [String] {
        ["-c:a", ffmpeg.has("aac_at") ? "aac_at" : "aac", "-b:a", bitrate]
    }

    /// Full re-encode arguments (video + audio) for `container`.
    static func encodeArgs(container: FileFormat, ffmpeg: FFmpeg, settings: EngineSettings, quality: VideoQuality = .standard, hasAudio: Bool = true) -> [String] {
        var args: [String]
        var audio: [String]
        switch container {
        case .webm:
            if ffmpeg.has("libvpx-vp9") {
                args = ["-c:v", "libvpx-vp9", "-crf", "\(quality.vp9CRF)", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p"]
            } else if ffmpeg.has("libsvtav1") {
                args = ["-c:v", "libsvtav1", "-crf", "\(quality.vp9CRF + 3)", "-preset", "8", "-pix_fmt", "yuv420p"]
            } else {
                args = ["-c:v", "libvpx", "-crf", "10", "-b:v", "2M", "-pix_fmt", "yuv420p"]
            }
            audio = ffmpeg.has("libopus") ? ["-c:a", "libopus", "-b:a", "128k", "-ar", "48000"] : ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"]
        case .avi:
            args = ["-c:v", "mpeg4", "-vtag", "xvid", "-q:v", "\(quality.mpeg4Q)", "-pix_fmt", "yuv420p"]
            audio = ffmpeg.has("libmp3lame") ? ["-c:a", "libmp3lame", "-q:a", "4"] : ["-c:a", "ac3", "-b:a", "192k"]
        case .wmv:
            let bitrate: String
            switch quality { case .standard: bitrate = "6M"; case .light: bitrate = "4M"; case .medium: bitrate = "2500k"; case .strong: bitrate = "1500k" }
            args = ["-c:v", "wmv2", "-b:v", bitrate, "-pix_fmt", "yuv420p"]
            audio = ["-c:a", "wmav2", "-b:a", "192k"]
        case .mkv, .mp4, .mov, .threeGP:
            args = h264Args(ffmpeg: ffmpeg, settings: settings, quality: quality)
            audio = aacArgs(ffmpeg: ffmpeg, bitrate: quality.audioBitrate)
            if container == .mp4 || container == .mov { args += ["-movflags", "+faststart"] }
        default:
            args = h264Args(ffmpeg: ffmpeg, settings: settings, quality: quality)
            audio = aacArgs(ffmpeg: ffmpeg, bitrate: quality.audioBitrate)
        }
        return args + (hasAudio ? audio : ["-an"])
    }

    /// Lossless remux arguments, if `info`'s streams fit `container` as-is.
    static func remuxArgs(container: FileFormat, info: MediaInfo) -> [String]? {
        let video = info.videoCodec ?? ""
        let audio = info.audioCodec
        switch container {
        case .mp4:
            guard ["h264", "hevc", "av1"].contains(video), audio == nil || ["aac", "mp3", "alac", "ac3", "eac3"].contains(audio!) else { return nil }
            return ["-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-movflags", "+faststart"] + (video == "hevc" ? ["-tag:v", "hvc1"] : [])
        case .mov:
            guard ["h264", "hevc", "prores", "mjpeg"].contains(video), audio == nil || ["aac", "mp3", "alac", "pcm_s16le", "pcm_s24le", "ac3"].contains(audio!) else { return nil }
            return ["-map", "0:v:0", "-map", "0:a?", "-c", "copy", "-movflags", "+faststart"] + (video == "hevc" ? ["-tag:v", "hvc1"] : [])
        case .mkv:
            return ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
        case .webm:
            guard ["vp8", "vp9", "av1"].contains(video), audio == nil || ["opus", "vorbis"].contains(audio!) else { return nil }
            return ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
        default:
            return nil
        }
    }

    /// Keeps dimensions even, which yuv420p encoders require.
    static let evenDimensions = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    /// Picks an output container for tools that keep "the same kind of file".
    static func toolContainer(for source: FileFormat) -> FileFormat {
        switch source {
        case .mp4, .mov, .mkv, .webm, .avi, .wmv: return source
        default: return .mp4
        }
    }

    static func toolAudioFormat(for source: FileFormat) -> FileFormat {
        switch source {
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma: return source
        case .aac: return .m4a
        default: return .m4a
        }
    }
}

/// Audio/video conversions powered by ffmpeg.
enum MediaConverter {
    static func convert(_ input: URL, to target: FileFormat, base: String, context: JobContext) async throws -> URL {
        let ffmpeg = try context.ffmpeg
        let info = try await ffmpeg.probe(input)
        let output = context.output(base: base, ext: target.fileExtension)
        let inputArgs = ["-i", input.path]

        var attempts: [[String]] = []
        switch target.category {
        case .audio:
            guard info.hasAudio else { throw OrbitError.invalidInput("\(input.lastPathComponent) has no audio track.") }
            let codec = try MediaCodecs.audioArgs(for: target, info: info, ffmpeg: ffmpeg)
            attempts.append(inputArgs + ["-map", "0:a:0", "-vn", "-sn", "-map_metadata", "0"] + codec)
            if codec.contains("copy") {
                attempts.append(inputArgs + ["-map", "0:a:0", "-vn", "-sn", "-map_metadata", "0"]
                                + (try MediaCodecs.audioArgs(for: target, info: info, ffmpeg: ffmpeg, bitrate: "256k")))
            }

        case .image where target == .gif:
            guard info.hasVideo else { throw OrbitError.invalidInput("\(input.lastPathComponent) has no video track.") }
            let filter = "fps=15,scale='min(720,iw)':-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
            attempts.append(inputArgs + ["-filter_complex", filter, "-an", "-loop", "0"])

        case .video:
            guard info.hasVideo else { throw OrbitError.invalidInput("\(input.lastPathComponent) has no video track.") }
            if let remux = MediaCodecs.remuxArgs(container: target, info: info) {
                attempts.append(inputArgs + remux)
            }
            let encode = MediaCodecs.encodeArgs(container: target, ffmpeg: ffmpeg, settings: context.settings, hasAudio: info.hasAudio)
            attempts.append(inputArgs + ["-map", "0:v:0", "-map", "0:a:0?", "-vf", MediaCodecs.evenDimensions] + encode)

        default:
            throw OrbitError.unsupported("\(target.name) output from media")
        }

        var lastError: Error?
        for args in attempts {
            do {
                try await ffmpeg.run(args + [output.path], duration: info.duration, progress: context.progress)
                return output
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: output)
                throw CancellationError()
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: output)
            }
        }
        throw lastError ?? OrbitError.failed("Conversion failed.")
    }
}
