import AppKit
import OrbitKit

/// Menu bar icon, its menu, and a drop target that opens the wheel when files are dragged onto it.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private unowned let env: AppEnvironment
    private var item: NSStatusItem?
    private let menu = NSMenu()

    init(env: AppEnvironment) {
        self.env = env
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.make()
        item.button?.toolTip = "Orbit — drag a file and tap a key"
        menu.delegate = self
        item.menu = menu
        if let button = item.button {
            let target = StatusDropView(frame: button.bounds)
            target.autoresizingMask = [.width, .height]
            target.onDragEntered = { [weak self] payload in self?.dragEntered(payload) }
            button.addSubview(target)
        }
        self.item = item
    }

    private func dragEntered(_ payload: DragPayload) {
        guard !env.wheel.isVisible, let button = item?.button, let window = button.window else { return }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        // Open the wheel just below the icon so the drag can continue straight into it.
        let point = CGPoint(x: frame.midX, y: frame.minY - WheelGeometry.ringOuter - 20)
        env.wheel.presentForDrag(payload: payload, mode: .convert, at: point)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let prefs = env.preferences
        let hint = NSMenuItem(title: "Drag a file, then tap \(prefs.convertKey.symbol) \(prefs.toolsKey.symbol) or \(prefs.actionsKey.symbol)", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Open Files…", action: #selector(openFiles), keyEquivalent: "o").target = self
        let selection = NSMenuItem(title: "Convert Finder Selection", action: #selector(finderSelection), keyEquivalent: "")
        selection.target = self
        if let equivalent = prefs.hotKeyPreset.menuEquivalent {
            selection.keyEquivalent = equivalent.key
            selection.keyEquivalentModifierMask = equivalent.flags
        }
        menu.addItem(selection)

        let jobs = env.jobs.jobs.prefix(8)
        if !jobs.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for job in jobs {
                let item = NSMenuItem(title: "", action: #selector(revealJob(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = job
                item.image = job.icon.resized(to: 16)
                switch job.state {
                case .queued: item.title = "\(job.title) — waiting"
                case .running: item.title = "\(job.title) — \(Int((job.progress ?? 0) * 100))%"
                case .done(let outputs): item.title = outputs.count == 1 ? outputs[0].lastPathComponent : "\(job.title) (\(outputs.count) files)"
                case .failed(let message): item.title = "⚠︎ \(job.title)"; item.toolTip = message
                case .cancelled: item.title = "\(job.title) — cancelled"
                }
                menu.addItem(item)
            }
            menu.addItem(withTitle: "Clear Recent", action: #selector(clearRecent), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        let pause = NSMenuItem(title: "Pause Drag Gesture", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = prefs.dragGestureEnabled ? .off : .on
        menu.addItem(pause)
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Welcome Guide", action: #selector(openWelcome), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Orbit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openFiles() { env.openFilesPanel() }
    @objc private func finderSelection() { env.openFinderSelection() }
    @objc private func togglePause() { env.preferences.dragGestureEnabled.toggle() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func openWelcome() { WelcomeWindowController.shared.show() }
    @objc private func clearRecent() { env.jobs.clearFinished() }

    @objc private func revealJob(_ sender: NSMenuItem) {
        guard let job = sender.representedObject as? Job else { return }
        if !job.outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(job.outputs)
        } else if case .failed(let message) = job.state {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "\(job.title) failed"
            alert.informativeText = message
            alert.runModal()
        }
    }
}

/// Transparent view over the status item button that notices file drags.
final class StatusDropView: NSView {
    var onDragEntered: ((DragPayload) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { fatalError() }

    // Clicks still belong to the status button underneath.
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let payload = DragPayload.read(from: sender.draggingPasteboard) { onDragEntered?(payload) }
        return []
    }
}

enum StatusIcon {
    /// A small orbit glyph drawn as a template image.
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setFill()
            NSColor.black.setStroke()
            NSBezierPath(ovalIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)).fill()
            let ring = NSBezierPath(ovalIn: CGRect(x: -7.6, y: -3.2, width: 15.2, height: 6.4))
            var transform = AffineTransform(translationByX: center.x, byY: center.y)
            transform.rotate(byDegrees: 25)
            ring.transform(using: transform)
            ring.lineWidth = 1.4
            ring.stroke()
            // A point on the tilted ellipse, front side.
            let t: CGFloat = -0.55
            let tilt: CGFloat = 25 * .pi / 180
            let ex: CGFloat = 7.6 * cos(t)
            let ey: CGFloat = 3.2 * sin(t)
            let moon = CGPoint(x: center.x + ex * cos(tilt) - ey * sin(tilt), y: center.y + ex * sin(tilt) + ey * cos(tilt))
            NSBezierPath(ovalIn: CGRect(x: moon.x - 1.9, y: moon.y - 1.9, width: 3.8, height: 3.8)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension NSImage {
    func resized(to side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        return image
    }
}
