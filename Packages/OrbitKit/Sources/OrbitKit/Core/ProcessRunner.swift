import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs external executables asynchronously, streaming output lines and honoring task cancellation.
public enum ProcessRunner {
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = stdin.map { _ in Pipe() }
        if let inPipe { process.standardInput = inPipe } else { process.standardInput = FileHandle.nullDevice }

        let collector = OutputCollector(onStdoutLine: onStdoutLine, onStderrLine: onStderrLine)
        let group = DispatchGroup()
        group.enter()
        group.enter()
        group.enter()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                collector.finish(stdout: true)
                group.leave()
            } else {
                collector.append(data, stdout: true)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                collector.finish(stdout: false)
                group.leave()
            } else {
                collector.append(data, stdout: false)
            }
        }
        process.terminationHandler = { _ in group.leave() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: OrbitError.failed("Could not launch \(executable.lastPathComponent): \(error.localizedDescription)"))
                    return
                }
                if let stdin, let inPipe {
                    DispatchQueue.global().async {
                        inPipe.fileHandleForWriting.write(stdin)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                group.notify(queue: .global()) {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let (out, err) = collector.snapshot()
                    continuation.resume(returning: ProcessResult(status: process.terminationStatus, stdout: out, stderr: err))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs and throws a readable error when the exit status is non-zero.
    @discardableResult
    public static func checked(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        toolName: String? = nil
    ) async throws -> ProcessResult {
        let result = try await run(executable, arguments, environment: environment, currentDirectory: currentDirectory)
        guard result.status == 0 else {
            let name = toolName ?? executable.lastPathComponent
            throw OrbitError.failed("\(name) failed: \(summarizeError(result.stderrString.isEmpty ? result.stdoutString : result.stderrString))")
        }
        return result
    }

    /// Picks the last few meaningful lines from a tool's error output.
    public static func summarizeError(_ text: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("frame=") && !$0.hasPrefix("size=") }
        let tail = lines.suffix(3).joined(separator: " — ")
        return tail.isEmpty ? "unknown error" : String(tail.prefix(400))
    }

    public static func which(_ name: String, extraPaths: [String] = []) -> URL? {
        let fm = FileManager.default
        var dirs = extraPaths + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/local/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var outLineBuffer = Data()
    private var errLineBuffer = Data()
    private let onStdoutLine: (@Sendable (String) -> Void)?
    private let onStderrLine: (@Sendable (String) -> Void)?

    init(onStdoutLine: (@Sendable (String) -> Void)?, onStderrLine: (@Sendable (String) -> Void)?) {
        self.onStdoutLine = onStdoutLine
        self.onStderrLine = onStderrLine
    }

    func append(_ data: Data, stdout: Bool) {
        lock.lock()
        var lines: [String] = []
        if stdout {
            out.append(data)
            if onStdoutLine != nil { lines = Self.drainLines(&outLineBuffer, adding: data) }
        } else {
            err.append(data)
            // Keep memory bounded for chatty tools such as ffmpeg.
            if err.count > 2_000_000 { err = err.suffix(500_000) }
            if onStderrLine != nil { lines = Self.drainLines(&errLineBuffer, adding: data) }
        }
        lock.unlock()
        let callback = stdout ? onStdoutLine : onStderrLine
        lines.forEach { callback?($0) }
    }

    func finish(stdout: Bool) {
        lock.lock()
        let rest = stdout ? outLineBuffer : errLineBuffer
        if stdout { outLineBuffer.removeAll() } else { errLineBuffer.removeAll() }
        lock.unlock()
        guard !rest.isEmpty else { return }
        let line = String(decoding: rest, as: UTF8.self)
        (stdout ? onStdoutLine : onStderrLine)?(line)
    }

    func snapshot() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (out, err)
    }

    private static func drainLines(_ buffer: inout Data, adding data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<index]
            if !lineData.isEmpty { lines.append(String(decoding: lineData, as: UTF8.self)) }
            buffer.removeSubrange(buffer.startIndex...index)
        }
        return lines
    }
}
