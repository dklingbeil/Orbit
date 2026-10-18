import AppKit

/// Scripting bridge to Pages, Keynote and Numbers (when installed) via AppleScript.
public struct IWork: Sendable {
    public var pages: Bool
    public var keynote: Bool
    public var numbers: Bool

    public init(pages: Bool, keynote: Bool, numbers: Bool) {
        self.pages = pages
        self.keynote = keynote
        self.numbers = numbers
    }

    public static let pagesID = "com.apple.iWork.Pages"
    public static let keynoteID = "com.apple.iWork.Keynote"
    public static let numbersID = "com.apple.iWork.Numbers"

    public static func detect() -> IWork {
        let ws = NSWorkspace.shared
        return IWork(
            pages: ws.urlForApplication(withBundleIdentifier: pagesID) != nil,
            keynote: ws.urlForApplication(withBundleIdentifier: keynoteID) != nil,
            numbers: ws.urlForApplication(withBundleIdentifier: numbersID) != nil
        )
    }

    public enum App: String, Sendable {
        case pages = "Pages", keynote = "Keynote", numbers = "Numbers"
    }

    /// Export classes understood by each app's `export … as …` command.
    public enum ExportKind: String, Sendable {
        case pdf = "PDF"
        case word = "Microsoft Word"
        case epub = "EPUB"
        case plainText = "unformatted text"
        case rtf = "formatted text"
        case powerpoint = "Microsoft PowerPoint"
        case excel = "Microsoft Excel"
        case csv = "CSV"
    }

    /// Opens `input` in `app` and exports it as `kind` to `output`.
    public static func export(_ input: URL, with app: App, as kind: ExportKind, to output: URL) async throws {
        let script = """
        set inFile to POSIX file \(quoted(input.path))
        set outFile to POSIX file \(quoted(output.path))
        tell application "\(app.rawValue)"
            set theDoc to open inFile
            export theDoc to outFile as \(kind.rawValue)
            close theDoc saving no
        end tell
        """
        try await runAppleScript(script, app: app)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw OrbitError.failed("\(app.rawValue) did not produce \(output.lastPathComponent).")
        }
    }

    /// Opens `input` in `app` and saves it in the app's native format (.pages / .key / .numbers).
    public static func saveNative(_ input: URL, with app: App, to output: URL) async throws {
        let script = """
        set inFile to POSIX file \(quoted(input.path))
        set outFile to POSIX file \(quoted(output.path))
        tell application "\(app.rawValue)"
            set theDoc to open inFile
            save theDoc in outFile
            close theDoc saving no
        end tell
        """
        try await runAppleScript(script, app: app)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw OrbitError.failed("\(app.rawValue) did not produce \(output.lastPathComponent).")
        }
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runAppleScript(_ source: String, app: App) async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", source])
        if result.status != 0 {
            let message = result.stderrString
            if message.contains("-1743") || message.contains("Not authorized") {
                throw OrbitError.failed("Orbit isn't allowed to control \(app.rawValue). Enable it in System Settings › Privacy & Security › Automation.")
            }
            throw OrbitError.failed("\(app.rawValue) failed: \(ProcessRunner.summarizeError(message))")
        }
    }
}
