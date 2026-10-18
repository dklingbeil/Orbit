import Foundation
import OrbitKit

/// `orbit` — the Orbit engine on the command line.
///
///     orbit caps
///     orbit menu photo.heic [--tools]
///     orbit convert --to webp photo.heic [more files…] [--out DIR]
///     orbit tool videoTrim --start 5 --end 12 clip.mov
///     orbit tool imageResize --option custom --text 1200w photo.jpg

let usage = """
usage:
  orbit caps                                   show detected engines
  orbit menu <files…> [--tools]                list conversions (or tools) for files
  orbit convert --to <format> <files…> [--out <dir>]
  orbit tool <tool> [--option <preset>] [--text <value>] [--password <pw>]
                    [--start <sec>] [--end <sec>] [--crop x,y,w,h] <files…> [--out <dir>]
  orbit tools                                  list tool identifiers
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("orbit: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func takeOption(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name) else { return nil }
    guard index + 1 < args.count else { fail("\(name) needs a value") }
    let value = args[index + 1]
    args.removeSubrange(index...(index + 1))
    return value
}

func takeFlag(_ name: String) -> Bool {
    guard let index = args.firstIndex(of: name) else { return false }
    args.remove(at: index)
    return true
}

func inputURLs() -> [URL] {
    let urls = args.map { URL(fileURLWithPath: $0).standardizedFileURL }
    guard !urls.isEmpty else { fail("no input files") }
    for url in urls where !FileManager.default.fileExists(atPath: url.path) { fail("no such file: \(url.path)") }
    return urls
}

func printTree(_ nodes: [MenuNode], indent: String = "") {
    for node in nodes {
        let state = node.disabledReason.map { "  [unavailable: \($0)]" } ?? ""
        var payload = ""
        if case .operation(let spec) = node.payload { payload = "  → \(spec)" }
        print("\(indent)\(node.title)\(payload)\(state)")
        printTree(node.children, indent: indent + "    ")
    }
}

func run(_ spec: OperationSpec, inputs: [URL], parameters: OperationParameters, outDir: URL?) async {
    let capabilities = Capabilities.detect()
    var settings = EngineSettings()
    settings.preferHardwareVideo = ProcessInfo.processInfo.environment["ORBIT_SOFTWARE_VIDEO"] == nil
    let groups: [[URL]] = spec.isCombined ? [inputs] : inputs.map { [$0] }
    var failures = 0
    for group in groups {
        let destination = outDir ?? group[0].deletingLastPathComponent()
        do {
            let work = try OutputNaming.makeWorkDirectory(near: destination)
            defer { try? FileManager.default.removeItem(at: work) }
            let context = JobContext(workDirectory: work, capabilities: capabilities, settings: settings, parameters: parameters) { value in
                if let value { FileHandle.standardError.write(Data(String(format: "\r%3.0f%%", value * 100).utf8)) }
            }
            let started = Date()
            let produced = try await OperationRunner.run(spec, inputs: group, context: context)
            let placed = try OutputNaming.place(produced, into: destination)
            FileHandle.standardError.write(Data("\r".utf8))
            for url in placed { print("\(url.path)\t(\(String(format: "%.2fs", Date().timeIntervalSince(started))))") }
        } catch {
            failures += 1
            FileHandle.standardError.write(Data("\rorbit: \(group.map(\.lastPathComponent).joined(separator: ", ")): \(error.localizedDescription)\n".utf8))
        }
    }
    exit(failures == 0 ? 0 : 2)
}

switch command {
case "caps":
    for (name, value) in Capabilities.detect().summary { print("\(name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(value)") }

case "tools":
    for tool in ToolID.allCases { print(tool.rawValue) }

case "menu":
    let tools = takeFlag("--tools")
    let selection = FileSelection(urls: inputURLs())
    let caps = Capabilities.detect()
    printTree(tools ? Catalog.toolsMenu(for: selection, capabilities: caps) : Catalog.convertMenu(for: selection, capabilities: caps))

case "convert":
    guard let formatName = takeOption("--to"), let format = FileFormat.withID(formatName) else { fail("--to <format> is required") }
    let out = takeOption("--out").map { URL(fileURLWithPath: $0) }
    await run(.convert(format), inputs: inputURLs(), parameters: OperationParameters(), outDir: out)

case "tool":
    guard let name = args.first, let tool = ToolID(rawValue: name) else { fail("unknown tool; run `orbit tools`") }
    args.removeFirst()
    var parameters = OperationParameters()
    let option = takeOption("--option")
    parameters.text = takeOption("--text")
    parameters.password = takeOption("--password")
    parameters.trimStart = takeOption("--start").flatMap(Timecode.parseDuration)
    parameters.trimEnd = takeOption("--end").flatMap(Timecode.parseDuration)
    if let crop = takeOption("--crop") {
        let v = crop.split(separator: ",").compactMap { Double($0) }
        guard v.count == 4 else { fail("--crop expects x,y,w,h") }
        parameters.cropRect = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
    let out = takeOption("--out").map { URL(fileURLWithPath: $0) }
    await run(.tool(tool, option), inputs: inputURLs(), parameters: parameters, outDir: out)

default:
    print(usage)
    exit(1)
}
