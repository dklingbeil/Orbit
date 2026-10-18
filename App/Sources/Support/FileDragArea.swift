import AppKit
import SwiftUI

/// A transparent area that drags files out as real file URLs.
///
/// SwiftUI's `onDrag` loses to `isMovableByWindowBackground` (the window moves instead), so drag
/// sources in our panels are plain AppKit views that refuse to move the window.
struct FileDragArea: NSViewRepresentable {
    var urls: [URL]
    var image: NSImage?
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> FileDragNSView { FileDragNSView() }

    func updateNSView(_ view: FileDragNSView, context: Context) {
        view.urls = urls
        view.image = image
        view.onDoubleClick = onDoubleClick
    }
}

final class FileDragNSView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var image: NSImage?
    var onDoubleClick: (() -> Void)?
    private var mouseDownEvent: NSEvent?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !urls.isEmpty else { return }
        mouseDownEvent = nil
        let point = convert(down.locationInWindow, from: nil)
        let items = urls.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let picture = image ?? NSWorkspace.shared.icon(forFile: url.path)
            var size = picture.size
            let scale = 72 / max(size.width, size.height, 1)
            size = CGSize(width: size.width * scale, height: size.height * scale)
            let offset = CGFloat(index) * 4
            item.setDraggingFrame(CGRect(x: point.x - size.width / 2 + offset, y: point.y - size.height / 2 - offset,
                                         width: size.width, height: size.height), contents: picture)
            return item
        }
        beginDraggingSession(with: items, event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }
}
