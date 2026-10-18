import Foundation

/// Headless LibreOffice, used for formats Apple frameworks can't render (PPTX, XLS, DOC, iWork imports).
public struct LibreOffice: Sendable {
    public let soffice: URL

    public static func locate() -> LibreOffice? {
        let fm = FileManager.default
        let candidates = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return LibreOffice(soffice: URL(fileURLWithPath: path))
        }
        if let found = ProcessRunner.which("soffice") { return LibreOffice(soffice: found) }
        return nil
    }

    /// Converts `input` with LibreOffice's `--convert-to` (e.g. "pdf", "xlsx", "docx", "pptx", "csv").
    /// Returns the produced file inside `outputDirectory`.
    public func convert(_ input: URL, to target: String, outputDirectory: URL) async throws -> URL {
        try await LibreOfficeQueue.shared.run {
            // A private profile keeps us from colliding with a LibreOffice window the user has open.
            let profile = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-libreoffice-profile", isDirectory: true)
            let filterTarget: String
            switch target {
            case "csv": filterTarget = "csv:Text - txt - csv (StarCalc):44,34,76,1"
            default: filterTarget = target
            }
            let args = [
                "-env:UserInstallation=\(profile.absoluteString)",
                "--headless", "--norestore", "--nologo", "--nodefault", "--nolockcheck",
                "--convert-to", filterTarget,
                "--outdir", outputDirectory.path,
                input.path,
            ]
            let result = try await ProcessRunner.run(soffice, args)
            let ext = target.split(separator: ":").first.map(String.init) ?? target
            let expected = outputDirectory.appendingPathComponent(
                (input.deletingPathExtension().lastPathComponent as NSString).appendingPathExtension(ext) ?? ""
            )
            guard result.status == 0, FileManager.default.fileExists(atPath: expected.path) else {
                let message = ProcessRunner.summarizeError(result.stderrString + result.stdoutString)
                throw OrbitError.failed("LibreOffice could not convert \(input.lastPathComponent): \(message)")
            }
            return expected
        }
    }
}

/// LibreOffice instances sharing a profile must not run concurrently.
actor LibreOfficeQueue {
    static let shared = LibreOfficeQueue()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await work()
    }
}
