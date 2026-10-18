import AppKit
import OrbitKit

/// What is being dragged: concrete files, or file promises (Photos, Mail, browsers…).
struct DragPayload {
    var urls: [URL]
    /// UTIs of promised files when the drag carries promises instead of file URLs.
    var promisedTypes: [String] = []

    var isPromise: Bool { urls.isEmpty && !promisedTypes.isEmpty }

    var selection: FileSelection {
        if isPromise {
            let placeholders = promisedTypes.enumerated().map { URL(fileURLWithPath: "/promised/\($0.offset)") }
            return FileSelection(urls: placeholders, formats: promisedTypes.map(FormatDetector.format(forUTI:)))
        }
        return FileSelection(urls: urls)
    }

    static func read(from pasteboard: NSPasteboard) -> DragPayload? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return DragPayload(urls: urls)
        }
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            let types = receivers.flatMap(\.fileTypes)
            if !types.isEmpty { return DragPayload(urls: [], promisedTypes: types) }
        }
        return nil
    }
}

/// Watches system-wide for file drags and modifier-key taps during them.
///
/// No Accessibility permission is needed: mouse-down is observed with a global event monitor, the
/// drag itself is detected through the shared drag pasteboard, and modifier state is polled.
@MainActor
final class DragMonitor {
    var isEnabled = true
    /// Open on key-down instead of a press-and-release tap.
    var triggerOnPress = false
    var watchedModifiers: NSEvent.ModifierFlags = [.shift, .command, .control]
    var modeForModifier: (NSEvent.ModifierFlags) -> WheelMode? = { _ in nil }
    var onTrigger: (WheelMode, DragPayload, NSPoint) -> Void = { _, _, _ in }
    var onDragEnded: () -> Void = {}

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var startChangeCount = 0
    private var payload: DragPayload?
    private var previousFlags: NSEvent.ModifierFlags = []
    private var pendingTap: (flag: NSEvent.ModifierFlags, at: Date, clean: Bool)?

    private let tapWindow: TimeInterval = 0.6
    private let dragPasteboard = NSPasteboard(name: .drag)

    init() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseWentDown() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseWentDown() }
            return event
        }
    }

    private func mouseWentDown() {
        guard isEnabled else { return }
        startChangeCount = dragPasteboard.changeCount
        payload = nil
        pendingTap = nil
        previousFlags = currentFlags()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func currentFlags() -> NSEvent.ModifierFlags {
        let raw = CGEventSource.flagsState(.combinedSessionState).rawValue
        return NSEvent.ModifierFlags(rawValue: UInt(raw)).intersection([.shift, .command, .control, .option])
    }

    @objc private func poll() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            finish()
            return
        }

        if payload == nil {
            guard dragPasteboard.changeCount != startChangeCount, let found = DragPayload.read(from: dragPasteboard) else { return }
            payload = found
            // Keys already held when the drag started (e.g. ⌥ to copy in Finder) don't count.
            previousFlags = currentFlags()
            return
        }

        let flags = currentFlags()
        defer { previousFlags = flags }
        guard flags != previousFlags else { return }

        let pressed = flags.subtracting(previousFlags)
        let released = previousFlags.subtracting(flags)

        // Any other key joining in turns the tap into a chord, which we ignore.
        if pendingTap != nil, !pressed.isEmpty { pendingTap?.clean = false }

        if let single = singleWatched(pressed), flags == single {
            if triggerOnPress {
                fire(single)
            } else {
                pendingTap = (single, Date(), true)
            }
            return
        }

        if let tap = pendingTap, released.contains(tap.flag) {
            pendingTap = nil
            if tap.clean, flags.isEmpty, Date().timeIntervalSince(tap.at) < tapWindow {
                fire(tap.flag)
            }
        }
    }

    private func singleWatched(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags? {
        for flag in [NSEvent.ModifierFlags.shift, .command, .control, .option] where flags == flag && watchedModifiers.contains(flag) {
            return flag
        }
        return nil
    }

    private func fire(_ flag: NSEvent.ModifierFlags) {
        guard let payload, let mode = modeForModifier(flag) else { return }
        onTrigger(mode, payload, NSEvent.mouseLocation)
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        let hadDrag = payload != nil
        payload = nil
        pendingTap = nil
        if hadDrag { onDragEnded() }
    }
}
