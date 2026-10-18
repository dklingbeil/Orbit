import AppKit
import QuickLookThumbnailing
import SwiftUI

/// A small always-on-top shelf that holds files until you drag them somewhere else.
@MainActor
final class FloatShelf: NSObject, NSWindowDelegate {
    private static var shelves: [FloatShelf] = []

    private let panel: NSPanel
    private let model: ShelfModel

    static func open(with urls: [URL]) {
        let shelf = FloatShelf(urls: urls)
        shelves.append(shelf)
        shelf.show()
    }

    private init(urls: [URL]) {
        model = ShelfModel(urls: urls)
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 230, height: 120),
                        styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow, .hudWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        model.onEmpty = { [weak self] in self?.panel.close() }
        let host = NSHostingView(rootView: ShelfView(model: model))
        panel.contentView = host
        model.onResize = { [weak self] height in
            guard let self else { return }
            var frame = self.panel.frame
            let delta = height - frame.height
            frame.size.height = height
            frame.origin.y -= delta
            self.panel.setFrame(frame, display: true, animate: false)
        }
        model.onResize?(model.preferredHeight)
    }

    private func show() {
        let mouse = NSEvent.mouseLocation
        let offset = CGFloat(FloatShelf.shelves.count - 1) * 24
        panel.setFrameTopLeftPoint(CGPoint(x: mouse.x + 24 + offset, y: mouse.y + 60 - offset))
        panel.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        FloatShelf.shelves.removeAll { $0 === self }
    }
}

@MainActor
final class ShelfModel: ObservableObject {
    @Published var urls: [URL]
    @Published var thumbnails: [URL: NSImage] = [:]
    var onEmpty: (() -> Void)?
    var onResize: ((CGFloat) -> Void)?

    init(urls: [URL]) {
        self.urls = urls
        urls.forEach(loadThumbnail)
    }

    var preferredHeight: CGFloat { min(420, 96 + CGFloat(urls.count) * 34) }

    func add(_ new: [URL]) {
        let fresh = new.filter { !urls.contains($0) }
        urls += fresh
        fresh.forEach(loadThumbnail)
        onResize?(preferredHeight)
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url }
        if urls.isEmpty { onEmpty?() } else { onResize?(preferredHeight) }
    }

    private func loadThumbnail(_ url: URL) {
        thumbnails[url] = NSWorkspace.shared.icon(forFile: url.path)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async { self?.thumbnails[url] = image }
        }
    }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                DragAllView(urls: model.urls, image: model.urls.first.flatMap { model.thumbnails[$0] } ?? NSImage())
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.urls.count == 1 ? model.urls[0].lastPathComponent : "\(model.urls.count) items")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("Drag to drop anywhere")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 14)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.urls, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(nsImage: model.thumbnails[url] ?? NSImage())
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 24, height: 24)
                            Text(url.lastPathComponent)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Button {
                                model.remove(url)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                        .help(url.path)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .frame(minWidth: 230, maxWidth: 230)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.add([url]) } }
                }
            }
            return true
        }
    }
}

/// Drags every file on the shelf at once.
struct DragAllView: NSViewRepresentable {
    var urls: [URL]
    var image: NSImage

    func makeNSView(context: Context) -> DragAllNSView { DragAllNSView() }

    func updateNSView(_ view: DragAllNSView, context: Context) {
        view.urls = urls
        view.image = image
        view.needsDisplay = true
    }
}

final class DragAllNSView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var image = NSImage()

    override func draw(_ dirtyRect: NSRect) {
        let count = min(urls.count, 3)
        for i in stride(from: count - 1, through: 0, by: -1) {
            let inset = CGFloat(i) * 3
            image.draw(in: bounds.insetBy(dx: 2 + inset, dy: 2 + inset).offsetBy(dx: inset, dy: -inset),
                       from: .zero, operation: .sourceOver, fraction: i == 0 ? 1 : 0.6)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseDown(with event: NSEvent) {}

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : .copy
    }
}
