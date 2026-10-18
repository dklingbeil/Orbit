import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey (no permissions required).
final class HotKey {
    let preset: HotKeyPreset
    private var reference: EventHotKeyRef?
    private let handler: () -> Void
    private let identifier: UInt32

    private static var nextID: UInt32 = 1
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandlerInstalled = false

    init?(preset: HotKeyPreset, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.preset = preset
        self.handler = handler
        self.identifier = HotKey.nextID
        HotKey.nextID += 1
        HotKey.installEventHandler()

        let hotKeyID = EventHotKeyID(signature: OSType(0x4F524254) /* 'ORBT' */, id: identifier)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else { return nil }
        HotKey.handlers[identifier] = handler
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        HotKey.handlers[identifier] = nil
    }

    private static func installEventHandler() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Reads the current Finder selection through Apple Events.
enum FinderSelection {
    static func current() -> [URL] {
        let source = """
        tell application "Finder"
            set theSelection to selection as alias list
            set output to ""
            repeat with anItem in theSelection
                set output to output & POSIX path of anItem & linefeed
            end repeat
            return output
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source),
              let result = script.executeAndReturnError(&error).stringValue else { return [] }
        return result.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}

/// "Open in Orbit" in Finder's Services / Quick Actions menu.
final class ServiceProvider: NSObject {
    @objc func openWheel(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async {
            AppEnvironment.shared.wheel.presentForKeyboard(urls: urls, mode: .convert)
        }
    }
}
