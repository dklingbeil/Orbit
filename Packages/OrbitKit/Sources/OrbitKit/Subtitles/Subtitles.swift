import Foundation

public struct SubtitleCue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
}

/// SRT ↔ VTT ↔ TXT, plus timing shifts.
enum SubtitleConverter {
    static func parse(_ source: String) -> [SubtitleCue] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let match = lines[timingIndex].firstMatch(of: #/((?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[,.]\d{1,3})/#),
                  let start = timestamp(String(match.1)), let end = timestamp(String(match.2)) else { continue }
            let text = lines[(timingIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: text))
        }
        return cues
    }

    static func timestamp(_ text: String) -> Double? {
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    static func format(_ seconds: Double, separator: String) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, separator, ms % 1000)
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(format(cue.start, separator: ",")) --> \(format(cue.end, separator: ","))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(format(cue.start, separator: ".")) --> \(format(cue.end, separator: "."))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// Transcript: tags stripped, repeated lines collapsed.
    static func plainText(_ cues: [SubtitleCue]) -> String {
        var lines: [String] = []
        for cue in cues {
            let clean = cue.text
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty, clean != lines.last { lines.append(clean) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func read(_ url: URL) throws -> [SubtitleCue] {
        let cues = parse(try DocumentConverter.readText(url))
        guard !cues.isEmpty else { throw OrbitError.invalidInput("No subtitles were found in \(url.lastPathComponent).") }
        return cues
    }

    static func render(_ cues: [SubtitleCue], as target: FileFormat) throws -> String {
        switch target {
        case .srt: return srt(cues)
        case .vtt: return vtt(cues)
        case .txt: return plainText(cues)
        default: throw OrbitError.unsupported("subtitles → \(target.name)")
        }
    }

    static func convert(_ input: URL, from source: FileFormat, to target: FileFormat, base: String, context: JobContext) throws -> URL {
        let output = context.output(base: base, ext: target.fileExtension)
        try render(try read(input), as: target).write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    static func shift(_ input: URL, option: String?, context: JobContext) throws -> URL {
        let raw = option == "custom" ? context.parameters.text ?? "" : option ?? ""
        guard let offset = Double(raw.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "s", with: "")
            .replacingOccurrences(of: "−", with: "-").trimmingCharacters(in: .whitespaces)) else {
            throw OrbitError.invalidInput("Enter a number of seconds, like 1.5 or -0.75.")
        }
        let format = FormatDetector.format(for: input) ?? .srt
        let cues = try read(input).map { cue in
            SubtitleCue(start: max(0, cue.start + offset), end: max(0, cue.end + offset), text: cue.text)
        }
        let label = offset >= 0 ? "+\(trim(offset))s" : "\(trim(offset))s"
        let output = context.output(base: "\(OutputNaming.baseName(of: input))-shifted\(label)", ext: format.fileExtension)
        try render(cues, as: format).write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
