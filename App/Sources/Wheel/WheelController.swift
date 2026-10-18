import AppKit
import OrbitKit

/// Shows the wheel, tracks the pointer or keyboard, and runs the chosen operation.
@MainActor
final class WheelController: NSObject, NSWindowDelegate {
    enum Interaction { case drag, keyboard }

    let model = WheelModel()
    private unowned let env: AppEnvironment
    private var panel: WheelPanel?
    private var container: WheelContainerView?
    private var payload = DragPayload(urls: [])
    private(set) var interaction: Interaction = .drag
    private var dropInFlight = false
    private var keyboardFlags: NSEvent.ModifierFlags = []
    private var keyboardTap: (flag: NSEvent.ModifierFlags, at: Date)?

    var isVisible: Bool { panel?.isVisible == true && model.shown }

    init(env: AppEnvironment) {
        self.env = env
    }

    // MARK: Presenting

    func presentForDrag(payload: DragPayload, mode: WheelMode, at screenPoint: NSPoint) {
        present(payload: payload, mode: mode, at: screenPoint, interaction: .drag)
    }

    func presentForKeyboard(urls: [URL], mode: WheelMode, at point: NSPoint? = nil) {
        guard !urls.isEmpty else { return }
        present(payload: DragPayload(urls: urls), mode: mode, at: point ?? NSEvent.mouseLocation, interaction: .keyboard)
    }

    private func present(payload: DragPayload, mode: WheelMode, at screenPoint: NSPoint, interaction: Interaction) {
        self.payload = payload
        self.interaction = interaction
        dropInFlight = false

        let panel = self.panel ?? makePanel()
        model.keyboard = interaction == .keyboard
        model.summary = SelectionSummary.make(for: payload)
        model.keys = Dictionary(uniqueKeysWithValues: WheelMode.allCases.map { ($0, env.preferences.key(for: $0).symbol) })
        setMode(mode, resetSelection: true)

        // Center the hub on the pointer, kept fully on screen.
        let screen = NSScreen.screens.first { $0.frame.contains(screenPoint) } ?? NSScreen.main
        var origin = CGPoint(x: screenPoint.x - WheelGeometry.center.x, y: screenPoint.y - WheelGeometry.center.y)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX - 40), visible.maxX - WheelGeometry.size.width + 40)
            origin.y = min(max(origin.y, visible.minY - 40), visible.maxY - WheelGeometry.size.height + 10)
        }
        panel.setFrameOrigin(origin)
        panel.allowsKey = interaction == .keyboard
        panel.alphaValue = 1

        if interaction == .keyboard {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(container)
            if !model.nodes.isEmpty { model.hit = .slice(0) }
        } else {
            panel.orderFrontRegardless()
        }
        container?.setDiskVisible(true)
        model.shown = true
    }

    private func makePanel() -> WheelPanel {
        let container = WheelContainerView(model: model)
        container.controller = self
        let panel = WheelPanel(contentView: container)
        panel.delegate = self
        self.panel = panel
        self.container = container
        return panel
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        model.shown = false
        container?.setDiskVisible(false)
        let closing = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self, !self.model.shown else { return }
            closing.orderOut(nil)
        }
    }

    /// The drag ended somewhere other than the wheel.
    func dragEnded() {
        guard interaction == .drag else { return }
        // The mouse-up can reach us slightly before the drop does; give the drop a moment to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.interaction == .drag, !self.dropInFlight else { return }
            self.dismiss()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--stay") { return }
        #endif
        if interaction == .keyboard { dismiss() }
    }

    // MARK: Modes

    func switchMode(_ mode: WheelMode) {
        guard mode != model.mode else { return }
        setMode(mode, resetSelection: interaction == .keyboard)
    }

    private func setMode(_ mode: WheelMode, resetSelection: Bool) {
        model.mode = mode
        let selection = payload.selection
        switch mode {
        case .convert: model.nodes = Catalog.convertMenu(for: selection, capabilities: env.capabilities)
        case .tools: model.nodes = Catalog.toolsMenu(for: selection, capabilities: env.capabilities)
        case .actions: model.nodes = FileActions.menu(for: payload, preferences: env.preferences)
        }
        model.expanded = nil
        model.hit = resetSelection && interaction == .keyboard && !model.nodes.isEmpty ? .slice(0) : .none
        if interaction == .keyboard, case .slice(let index) = model.hit { expandIfNeeded(index) }
    }

    // MARK: Pointer

    private func hit(at point: CGPoint) -> WheelGeometry.Hit {
        WheelGeometry.hit(point, sliceCount: model.nodes.count, expanded: model.expanded,
                          childCount: model.children.count, tabFrames: model.tabFrames)
    }

    func pointerMoved(to point: CGPoint?) {
        guard let point else {
            if interaction == .drag { model.hit = .none }
            return
        }
        let hit = hit(at: point)
        switch hit {
        case .slice(let index):
            expandIfNeeded(index)
        case .tab(let mode):
            switchMode(mode)
        case .none where model.expanded != nil:
            // Between the ring and the options: keep the options open.
            break
        default:
            break
        }
        model.hit = hit
    }

    private func expandIfNeeded(_ index: Int) {
        guard model.nodes.indices.contains(index) else { return }
        model.expanded = model.nodes[index].children.isEmpty || !model.nodes[index].isEnabled ? nil : index
    }

    func clicked(at point: CGPoint) {
        let hit = hit(at: point)
        switch hit {
        case .hub, .none: dismiss()
        case .tab(let mode): switchMode(mode)
        case .slice, .child:
            model.hit = hit
            if let node = model.target { activate(node) }
        }
    }

    // MARK: Drag & drop

    func dragMoved(to point: CGPoint) -> NSDragOperation {
        pointerMoved(to: point)
        return model.target?.resolved != nil ? .copy : []
    }

    func canDrop(at point: CGPoint) -> Bool {
        pointerMoved(to: point)
        return model.target?.resolved != nil
    }

    func performDrop(_ info: NSDraggingInfo, at point: CGPoint) -> Bool {
        pointerMoved(to: point)
        guard let node = model.target, node.resolved != nil else { return false }
        dropInFlight = true

        // Prefer what's actually on the dragging pasteboard (it's authoritative at drop time).
        if let dropped = DragPayload.read(from: info.draggingPasteboard) { payload = dropped }
        let receivers = (info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.payload.isPromise, !receivers.isEmpty {
                self.receivePromises(receivers) { urls in
                    guard !urls.isEmpty else { return }
                    self.payload = DragPayload(urls: urls)
                    self.activate(node)
                }
                self.dismiss()
            } else {
                self.activate(node)
            }
            self.dropInFlight = false
        }
        return true
    }

    private func receivePromises(_ receivers: [NSFilePromiseReceiver], completion: @escaping ([URL]) -> Void) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Orbit Promises", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: OperationQueue()) { url, error in
                if error == nil { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    // MARK: Keyboard

    func handleKey(_ event: NSEvent) -> Bool {
        let count = model.nodes.count
        switch Int(event.keyCode) {
        case 53: // escape
            dismiss()
        case 36, 76, 49: // return, enter, space
            if let node = model.target { activate(node) } else { NSSound.beep() }
        case 48: // tab
            switchMode(event.modifierFlags.contains(.shift) ? model.mode.previous : model.mode.next)
        case 123, 124: // left, right
            let delta = event.keyCode == 124 ? 1 : -1
            if case .child(let index) = model.hit, !model.children.isEmpty {
                model.hit = .child((index + delta + model.children.count) % model.children.count)
            } else if count > 0 {
                let current = model.hoveredIndex ?? (delta > 0 ? -1 : 0)
                let next = (current + delta + count) % count
                model.hit = .slice(next)
                expandIfNeeded(next)
            }
        case 126: // up: into the options ring
            if case .slice(let index) = model.hit, !model.nodes[index].children.isEmpty {
                expandIfNeeded(index)
                model.hit = .child(0)
            }
        case 125: // down: back to the main ring
            if case .child = model.hit, let expanded = model.expanded { model.hit = .slice(expanded) }
        default:
            if let digit = Int(event.charactersIgnoringModifiers ?? ""), digit >= 1, digit <= count {
                model.hit = .slice(digit - 1)
                expandIfNeeded(digit - 1)
            } else {
                return false
            }
        }
        return true
    }

    /// Modifier taps switch wheels in keyboard mode as well.
    func handleFlags(_ flags: NSEvent.ModifierFlags) {
        let relevant = flags.intersection([.shift, .command, .control, .option])
        if relevant.isEmpty {
            if let tap = keyboardTap, Date().timeIntervalSince(tap.at) < 0.6, let mode = env.preferences.mode(for: tap.flag) {
                switchMode(mode)
            }
            keyboardTap = nil
        } else if [NSEvent.ModifierFlags.shift, .command, .control, .option].contains(relevant), keyboardFlags.isEmpty {
            keyboardTap = (relevant, Date())
        } else {
            keyboardTap = nil
        }
        keyboardFlags = relevant
    }

    #if DEBUG
    /// Developer hooks driven by launch arguments (see AppDelegate).
    func debugHover(_ id: String) {
        if let index = model.nodes.firstIndex(where: { $0.id == id }) {
            model.hit = .slice(index)
            expandIfNeeded(index)
        } else if let parent = model.nodes.firstIndex(where: { $0.children.contains { $0.id == id } }) {
            model.expanded = parent
            model.hit = .child(model.nodes[parent].children.firstIndex { $0.id == id }!)
        }
    }

    func debugActivate(_ id: String) {
        debugHover(id)
        if let node = model.target { activate(node) }
    }
    #endif

    // MARK: Running

    private func activate(_ node: MenuNode) {
        guard let target = node.resolved else {
            NSSound.beep()
            return
        }
        let urls = payload.urls
        dismiss()
        guard !urls.isEmpty else { return }

        switch target.payload {
        case .operation(let spec):
            Task { @MainActor in
                guard let parameters = await self.gatherParameters(for: target, spec: spec, urls: urls) else { return }
                self.env.jobs.run(spec, inputs: urls, parameters: parameters, title: target.detail)
            }
        case .action(let id):
            FileActions.perform(id, urls: urls, env: env)
        case .none:
            break
        }
    }

    private func gatherParameters(for node: MenuNode, spec: OperationSpec, urls: [URL]) async -> OperationParameters? {
        var parameters = OperationParameters()
        switch node.requirement {
        case .none:
            break
        case .text(let title, let message, let placeholder, let initial):
            guard let text = Prompts.text(title: title, message: message, placeholder: placeholder, initial: initial) else { return nil }
            parameters.text = text
        case .password(let title, let message, let confirm):
            guard let password = Prompts.password(title: title, message: message, confirm: confirm) else { return nil }
            parameters.password = password
        case .trimRange:
            guard let url = urls.first, let range = await TrimEditor.run(for: url, ffmpeg: env.capabilities.ffmpeg) else { return nil }
            parameters.trimStart = range.lowerBound
            parameters.trimEnd = range.upperBound
        case .cropRect:
            guard let url = urls.first else { return nil }
            let isVideo = FormatDetector.format(for: url)?.category == .video
            guard let rect = await CropEditor.run(for: url, isVideo: isVideo, ffmpeg: env.capabilities.ffmpeg) else { return nil }
            parameters.cropRect = rect
        }
        return parameters
    }
}
