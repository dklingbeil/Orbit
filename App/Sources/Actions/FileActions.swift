import AppKit
import OrbitKit

/// The ⌃ Actions wheel: things to do with files that aren't conversions.
@MainActor
enum FileActions {
    static func menu(for payload: DragPayload, preferences: Preferences) -> [MenuNode] {
        let fm = FileManager.default
        func folderNode(_ url: URL, title: String? = nil) -> MenuNode {
            MenuNode(id: "action.move.\(url.path)", title: title ?? fm.displayName(atPath: url.path),
                     detail: "Move to \(fm.displayName(atPath: url.path))", payload: .action("move:\(url.path)"))
        }

        var destinations: [MenuNode] = []
        for path in preferences.recentMoveDestinations where fm.fileExists(atPath: path) {
            destinations.append(folderNode(URL(fileURLWithPath: path)))
        }
        for directory in [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory] {
            if let url = fm.urls(for: directory, in: .userDomainMask).first,
               !destinations.contains(where: { $0.id == "action.move.\(url.path)" }) {
                destinations.append(folderNode(url))
            }
        }
        destinations.append(MenuNode(id: "action.move.choose", title: "Choose…", detail: "Move to a folder you pick", payload: .action("move:choose")))

        let promised = payload.isPromise ? "Not available for files from other apps" : nil
        return [
            MenuNode(id: "action.airdrop", title: "AirDrop", detail: "Share with AirDrop", symbol: "dot.radiowaves.up.forward",
                     payload: .action("airdrop"), disabledReason: promised),
            MenuNode(id: "action.float", title: "Float", detail: "Keep in a floating shelf", symbol: "pin",
                     payload: .action("float"), disabledReason: promised),
            MenuNode(id: "action.copy", title: "Copy", detail: "Copy to the clipboard", symbol: "doc.on.clipboard",
                     payload: .action("copy"), disabledReason: promised),
            MenuNode(id: "action.move", title: "Move", detail: "Move to a folder", symbol: "folder",
                     children: destinations, disabledReason: promised),
            MenuNode(id: "action.path", title: "Path", detail: "Copy the path", symbol: "link", children: [
                MenuNode(id: "action.path.full", title: "Path", detail: "Copy the full path", payload: .action("path:full")),
                MenuNode(id: "action.path.shell", title: "Shell", detail: "Copy a shell-quoted path", payload: .action("path:shell")),
                MenuNode(id: "action.path.name", title: "Name", detail: "Copy the file name", payload: .action("path:name")),
                MenuNode(id: "action.path.url", title: "URL", detail: "Copy a file:// URL", payload: .action("path:url")),
            ], disabledReason: promised),
            MenuNode(id: "action.terminal", title: "Terminal", detail: "Open a terminal here", symbol: "terminal",
                     payload: .action("terminal"), disabledReason: promised),
        ]
    }

    static func perform(_ id: String, urls: [URL], env: AppEnvironment) {
        guard !urls.isEmpty else { return }
        let hud = env.jobs.hud
        let fm = FileManager.default

        switch id {
        case "airdrop":
            NSApp.activate(ignoringOtherApps: true)
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                hud.toast("AirDrop isn't available", symbol: "exclamationmark.triangle")
                return
            }
            service.perform(withItems: urls)

        case "float":
            FloatShelf.open(with: urls)

        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            hud.toast(urls.count == 1 ? "Copied “\(urls[0].lastPathComponent)”" : "Copied \(urls.count) items", symbol: "doc.on.clipboard")

        case let move where move.hasPrefix("move:"):
            let target = String(move.dropFirst(5))
            let destination: URL
            if target == "choose" {
                NSApp.activate(ignoringOtherApps: true)
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.prompt = "Move Here"
                panel.message = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to…" : "Move \(urls.count) items to…"
                guard panel.runModal() == .OK, let chosen = panel.url else { return }
                destination = chosen
            } else {
                destination = URL(fileURLWithPath: target)
            }
            var moved: [URL] = []
            for url in urls where url.deletingLastPathComponent().standardizedFileURL != destination.standardizedFileURL {
                let final = OutputNaming.uniqueURL(in: destination, fileName: url.lastPathComponent)
                do {
                    try fm.moveItem(at: url, to: final)
                    moved.append(final)
                } catch {
                    hud.toast("Couldn't move \(url.lastPathComponent): \(error.localizedDescription)", symbol: "exclamationmark.triangle")
                    return
                }
            }
            env.preferences.rememberMoveDestination(destination)
            hud.toast("Moved to \(fm.displayName(atPath: destination.path))", symbol: "folder", reveal: moved)

        case let path where path.hasPrefix("path:"):
            let style = path.dropFirst(5)
            let text: String
            switch style {
            case "shell": text = urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            case "name": text = urls.map(\.lastPathComponent).joined(separator: "\n")
            case "url": text = urls.map(\.absoluteString).joined(separator: "\n")
            default: text = urls.map(\.path).joined(separator: "\n")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            hud.toast("Copied \(style == "name" ? "name" : "path")", symbol: "link")

        case "terminal":
            var isDirectory: ObjCBool = false
            let first = urls[0]
            let folder = fm.fileExists(atPath: first.path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? first : first.deletingLastPathComponent()
            let bundleID = env.preferences.terminalBundleID
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())

        default:
            break
        }
    }

    /// Terminal apps we know how to open a folder in.
    static var installedTerminals: [(name: String, bundleID: String)] {
        let candidates = [
            ("Terminal", "com.apple.Terminal"),
            ("iTerm", "com.googlecode.iterm2"),
            ("Ghostty", "com.mitchellh.ghostty"),
            ("Warp", "dev.warp.Warp-Stable"),
            ("WezTerm", "com.github.wez.wezterm"),
            ("kitty", "net.kovidgoyal.kitty"),
            ("Alacritty", "org.alacritty"),
        ]
        return candidates.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.1) != nil }
    }
}
