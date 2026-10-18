import AppKit
import Carbon.HIToolbox

enum ModifierKey: String, CaseIterable, Identifiable {
    case shift, command, control, option

    var id: String { rawValue }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        }
    }
    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        }
    }
    var name: String {
        switch self {
        case .shift: return "Shift"
        case .command: return "Command"
        case .control: return "Control"
        case .option: return "Option"
        }
    }
}

enum TriggerStyle: String, CaseIterable, Identifiable {
    case tap, press
    var id: String { rawValue }
    var title: String { self == .tap ? "Tap the key" : "Press the key" }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case nextToOriginal, downloads, desktop, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nextToOriginal: return "Next to the original"
        case .downloads: return "Downloads"
        case .desktop: return "Desktop"
        case .custom: return "Custom folder…"
        }
    }
}

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case off, controlOptionSpace, optionCommandO, controlShiftSpace, optionSpace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .controlOptionSpace: return "⌃⌥Space"
        case .optionCommandO: return "⌥⌘O"
        case .controlShiftSpace: return "⌃⇧Space"
        case .optionSpace: return "⌥Space"
        }
    }
    /// Carbon key code and modifier mask.
    var binding: (keyCode: UInt32, modifiers: UInt32)? {
        switch self {
        case .off: return nil
        case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .optionCommandO: return (UInt32(kVK_ANSI_O), UInt32(optionKey | cmdKey))
        case .controlShiftSpace: return (UInt32(kVK_Space), UInt32(controlKey | shiftKey))
        case .optionSpace: return (UInt32(kVK_Space), UInt32(optionKey))
        }
    }
    var menuEquivalent: (key: String, flags: NSEvent.ModifierFlags)? {
        switch self {
        case .off: return nil
        case .controlOptionSpace: return (" ", [.control, .option])
        case .optionCommandO: return ("o", [.option, .command])
        case .controlShiftSpace: return (" ", [.control, .shift])
        case .optionSpace: return (" ", [.option])
        }
    }
}

/// UserDefaults-backed settings, observable from SwiftUI.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var dragGestureEnabled: Bool { didSet { defaults.set(dragGestureEnabled, forKey: "dragGestureEnabled") } }
    @Published var triggerStyle: TriggerStyle { didSet { defaults.set(triggerStyle.rawValue, forKey: "triggerStyle") } }
    @Published var convertKey: ModifierKey { didSet { defaults.set(convertKey.rawValue, forKey: "convertKey") } }
    @Published var toolsKey: ModifierKey { didSet { defaults.set(toolsKey.rawValue, forKey: "toolsKey") } }
    @Published var actionsKey: ModifierKey { didSet { defaults.set(actionsKey.rawValue, forKey: "actionsKey") } }
    @Published var hotKeyPreset: HotKeyPreset { didSet { defaults.set(hotKeyPreset.rawValue, forKey: "hotKeyPreset") } }

    @Published var outputLocation: OutputLocation { didSet { defaults.set(outputLocation.rawValue, forKey: "outputLocation") } }
    @Published var customOutputPath: String { didSet { defaults.set(customOutputPath, forKey: "customOutputPath") } }
    @Published var revealInFinder: Bool { didSet { defaults.set(revealInFinder, forKey: "revealInFinder") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    @Published var notifyWhenDone: Bool { didSet { defaults.set(notifyWhenDone, forKey: "notifyWhenDone") } }
    @Published var copyRecognizedText: Bool { didSet { defaults.set(copyRecognizedText, forKey: "copyRecognizedText") } }

    @Published var imageQuality: Double { didSet { defaults.set(imageQuality, forKey: "imageQuality") } }
    @Published var pdfDPI: Double { didSet { defaults.set(pdfDPI, forKey: "pdfDPI") } }
    @Published var preferHardwareVideo: Bool { didSet { defaults.set(preferHardwareVideo, forKey: "preferHardwareVideo") } }
    @Published var keepMetadata: Bool { didSet { defaults.set(keepMetadata, forKey: "keepMetadata") } }
    @Published var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") } }
    @Published var terminalBundleID: String { didSet { defaults.set(terminalBundleID, forKey: "terminalBundleID") } }

    @Published var recentMoveDestinations: [String] { didSet { defaults.set(recentMoveDestinations, forKey: "recentMoveDestinations") } }
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    private init() {
        defaults.register(defaults: [
            "dragGestureEnabled": true,
            "triggerStyle": TriggerStyle.tap.rawValue,
            "convertKey": ModifierKey.shift.rawValue,
            "toolsKey": ModifierKey.command.rawValue,
            "actionsKey": ModifierKey.control.rawValue,
            "hotKeyPreset": HotKeyPreset.controlOptionSpace.rawValue,
            "outputLocation": OutputLocation.nextToOriginal.rawValue,
            "revealInFinder": false,
            "playSound": true,
            "notifyWhenDone": true,
            "copyRecognizedText": true,
            "imageQuality": 0.85,
            "pdfDPI": 300.0,
            "preferHardwareVideo": true,
            "keepMetadata": true,
            "terminalBundleID": "com.apple.Terminal",
        ])
        dragGestureEnabled = defaults.bool(forKey: "dragGestureEnabled")
        triggerStyle = TriggerStyle(rawValue: defaults.string(forKey: "triggerStyle") ?? "") ?? .tap
        convertKey = ModifierKey(rawValue: defaults.string(forKey: "convertKey") ?? "") ?? .shift
        toolsKey = ModifierKey(rawValue: defaults.string(forKey: "toolsKey") ?? "") ?? .command
        actionsKey = ModifierKey(rawValue: defaults.string(forKey: "actionsKey") ?? "") ?? .control
        hotKeyPreset = HotKeyPreset(rawValue: defaults.string(forKey: "hotKeyPreset") ?? "") ?? .controlOptionSpace
        outputLocation = OutputLocation(rawValue: defaults.string(forKey: "outputLocation") ?? "") ?? .nextToOriginal
        customOutputPath = defaults.string(forKey: "customOutputPath") ?? ""
        revealInFinder = defaults.bool(forKey: "revealInFinder")
        playSound = defaults.bool(forKey: "playSound")
        notifyWhenDone = defaults.bool(forKey: "notifyWhenDone")
        copyRecognizedText = defaults.bool(forKey: "copyRecognizedText")
        imageQuality = defaults.double(forKey: "imageQuality")
        pdfDPI = defaults.double(forKey: "pdfDPI")
        preferHardwareVideo = defaults.bool(forKey: "preferHardwareVideo")
        keepMetadata = defaults.bool(forKey: "keepMetadata")
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? ""
        terminalBundleID = defaults.string(forKey: "terminalBundleID") ?? "com.apple.Terminal"
        recentMoveDestinations = defaults.stringArray(forKey: "recentMoveDestinations") ?? []
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
    }

    func key(for mode: WheelMode) -> ModifierKey {
        switch mode {
        case .convert: return convertKey
        case .tools: return toolsKey
        case .actions: return actionsKey
        }
    }

    func mode(for flag: NSEvent.ModifierFlags) -> WheelMode? {
        WheelMode.allCases.first { key(for: $0).flag == flag }
    }

    var watchedModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(WheelMode.allCases.map { key(for: $0).flag })
    }

    func rememberMoveDestination(_ url: URL) {
        var list = recentMoveDestinations.filter { $0 != url.path }
        list.insert(url.path, at: 0)
        recentMoveDestinations = Array(list.prefix(3))
    }

    /// Where results of a job on `inputs` should be saved.
    func outputDirectory(for inputs: [URL]) -> URL {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        switch outputLocation {
        case .downloads:
            return downloads
        case .desktop:
            return fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? downloads
        case .custom:
            if !customOutputPath.isEmpty { return URL(fileURLWithPath: customOutputPath) }
            return downloads
        case .nextToOriginal:
            guard let parent = inputs.first?.deletingLastPathComponent() else { return downloads }
            // Temporary files (file promises, our sample) and read-only locations fall back to Downloads.
            if parent.path.hasPrefix(fm.temporaryDirectory.path) || parent.path.hasPrefix("/private/var/folders")
                || parent.path.hasPrefix(SampleFile.directory.path) || !fm.isWritableFile(atPath: parent.path) {
                return downloads
            }
            return parent
        }
    }
}
