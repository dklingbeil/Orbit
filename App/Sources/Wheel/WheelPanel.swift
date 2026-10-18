import AppKit
import SwiftUI

/// Borderless, transparent, non-activating panel that floats above everything (including full-screen apps).
final class WheelPanel: NSPanel {
    var allowsKey = false

    init(contentView: NSView) {
        super.init(contentRect: CGRect(origin: .zero, size: WheelGeometry.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.contentView = contentView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isMovable = false
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Hosts the SwiftUI wheel and handles drags, mouse and keyboard in AppKit terms.
final class WheelContainerView: NSView {
    weak var controller: WheelController?
    private let effectView = NSVisualEffectView()
    private let shadowView = NSView()
    private let hostingView: NSHostingView<WheelView>
    private var trackingArea: NSTrackingArea?

    init(model: WheelModel) {
        hostingView = NSHostingView(rootView: WheelView(model: model))
        super.init(frame: CGRect(origin: .zero, size: WheelGeometry.size))
        wantsLayer = true

        let disk = CGRect(x: WheelGeometry.center.x - WheelGeometry.ringOuter - 6, y: WheelGeometry.center.y - WheelGeometry.ringOuter - 6,
                          width: (WheelGeometry.ringOuter + 6) * 2, height: (WheelGeometry.ringOuter + 6) * 2)

        shadowView.frame = disk
        shadowView.wantsLayer = true
        shadowView.layer?.shadowPath = CGPath(ellipseIn: CGRect(origin: .zero, size: disk.size), transform: nil)
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOpacity = 0.32
        shadowView.layer?.shadowRadius = 18
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -6)
        addSubview(shadowView)

        effectView.frame = disk
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = NSImage(size: disk.size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        addSubview(effectView)

        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)

        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { fatalError() }

    func setDiskVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.16 : 0.1
            effectView.animator().alphaValue = visible ? 1 : 0
            shadowView.animator().alphaValue = visible ? 1 : 0
        }
    }

    // All mouse handling happens here rather than in SwiftUI.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func local(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) { controller?.pointerMoved(to: local(event)) }
    override func mouseExited(with event: NSEvent) { controller?.pointerMoved(to: nil) }
    override func mouseDown(with event: NSEvent) { controller?.clicked(at: local(event)) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) { if controller?.handleKey(event) != true { super.keyDown(with: event) } }
    override func flagsChanged(with event: NSEvent) { controller?.handleFlags(event.modifierFlags) }

    // MARK: Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragMoved(to: convert(sender.draggingLocation, from: nil)) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragMoved(to: convert(sender.draggingLocation, from: nil)) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.pointerMoved(to: nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.canDrop(at: convert(sender.draggingLocation, from: nil)) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.performDrop(sender, at: convert(sender.draggingLocation, from: nil)) ?? false
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }
}
