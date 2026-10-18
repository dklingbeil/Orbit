import AppKit
import AVFoundation
import ImageIO
import OrbitKit

/// A crop window for images and video frames. Returns a pixel rectangle (top-left origin).
@MainActor
final class CropEditor: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var cropView: CropView!
    private var sizeLabel: NSTextField!
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private static var current: CropEditor?

    private static let aspects: [(String, CGFloat?)] = [
        ("Freeform", nil), ("Original", -1), ("Square 1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5),
        ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:5", 0.8),
    ]

    static func run(for url: URL, isVideo: Bool, ffmpeg: FFmpeg?) async -> CGRect? {
        NSApp.activate(ignoringOtherApps: true)
        guard let (image, pixelSize) = await loadFrame(url: url, isVideo: isVideo, ffmpeg: ffmpeg) else {
            let alert = NSAlert()
            alert.messageText = "Couldn't open “\(url.lastPathComponent)” for cropping."
            alert.runModal()
            return nil
        }
        let editor = CropEditor()
        current = editor
        let rect = await editor.present(image: image, pixelSize: pixelSize, title: url.lastPathComponent)
        current = nil
        return rect
    }

    private func present(image: CGImage, pixelSize: CGSize, title: String) async -> CGRect? {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Crop “\(title)”"
        window.minSize = CGSize(width: 520, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating

        cropView = CropView(image: image, pixelSize: pixelSize)
        cropView.onChange = { [weak self] in self?.updateLabel() }

        let aspect = NSPopUpButton(frame: .zero, pullsDown: false)
        for (name, _) in Self.aspects { aspect.addItem(withTitle: name) }
        aspect.target = self
        aspect.action = #selector(aspectChanged(_:))

        sizeLabel = NSTextField(labelWithString: "")
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor

        let reset = NSButton(title: "Reset", target: self, action: #selector(resetSelection))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let crop = NSButton(title: "Crop", target: self, action: #selector(confirm))
        crop.keyEquivalent = "\r"

        let bar = NSStackView(views: [aspect, sizeLabel, NSView(), reset, cancel, crop])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)
        bar.setHuggingPriority(.defaultHigh, for: .vertical)

        let stack = NSStackView(views: [cropView, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        cropView.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        updateLabel()

        return await withCheckedContinuation { self.continuation = $0 }
    }

    private func updateLabel() {
        let rect = cropView.selection.integral
        sizeLabel.stringValue = "\(Int(rect.width)) × \(Int(rect.height)) px"
    }

    @objc private func aspectChanged(_ sender: NSPopUpButton) {
        var ratio = Self.aspects[sender.indexOfSelectedItem].1
        if ratio == -1 { ratio = cropView.pixelSize.width / cropView.pixelSize.height }
        cropView.setAspect(ratio)
        updateLabel()
    }

    @objc private func resetSelection() {
        cropView.reset()
        updateLabel()
    }

    @objc private func confirm() { finish(cropView.selection.integral) }
    @objc private func cancel() { finish(nil) }

    private func finish(_ rect: CGRect?) {
        guard let continuation else { return }
        self.continuation = nil
        window?.delegate = nil
        window?.close()
        let full = CGRect(origin: .zero, size: cropView.pixelSize)
        if let rect, rect.width >= 2, rect.height >= 2 {
            continuation.resume(returning: rect.intersection(full))
        } else {
            continuation.resume(returning: nil)
        }
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    // MARK: Loading

    private static func loadFrame(url: URL, isVideo: Bool, ffmpeg: FFmpeg?) async -> (CGImage, CGSize)? {
        if !isVideo {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return svgFrame(url) }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            var width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            var height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            if orientation >= 5 { swap(&width, &height) }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 2400]
            guard width > 0, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return svgFrame(url) }
            return (image, CGSize(width: width, height: height))
        }

        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.seconds > 0 {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            let time = CMTime(seconds: duration.seconds / 3, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                return (image, CGSize(width: image.width, height: image.height))
            }
        }
        // Fall back to ffmpeg for formats AVFoundation can't decode.
        guard let ffmpeg else { return nil }
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-crop-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        let info = try? await ffmpeg.probe(url)
        let at = String(format: "%.3f", (info?.duration ?? 0) / 3)
        guard (try? await ffmpeg.run(["-ss", at, "-i", url.path, "-frames:v", "1", "-update", "1", png.path], duration: nil)) != nil,
              let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image, CGSize(width: image.width, height: image.height))
    }

    private static func svgFrame(_ url: URL) -> (CGImage, CGSize)? {
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (cg, CGSize(width: cg.width, height: cg.height))
    }
}

/// Image with a draggable, resizable crop rectangle.
final class CropView: NSView {
    let image: CGImage
    let pixelSize: CGSize
    private(set) var selection: CGRect
    private var aspect: CGFloat?
    var onChange: (() -> Void)?

    private enum DragMode { case none, move(CGPoint), resize(CGPoint /* anchor */, horizontal: Bool, vertical: Bool), create(CGPoint) }
    private var drag: DragMode = .none
    private var startSelection = CGRect.zero

    init(image: CGImage, pixelSize: CGSize) {
        self.image = image
        self.pixelSize = pixelSize
        self.selection = CGRect(origin: .zero, size: pixelSize).insetBy(dx: pixelSize.width * 0.1, dy: pixelSize.height * 0.1)
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 560))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func reset() {
        selection = CGRect(origin: .zero, size: pixelSize)
        if let aspect { selection = fitted(selection, aspect: aspect) }
        needsDisplay = true
    }

    func setAspect(_ ratio: CGFloat?) {
        aspect = ratio
        if let ratio { selection = fitted(selection, aspect: ratio) }
        needsDisplay = true
    }

    /// Largest rect with `aspect` centered inside `rect`, clamped to the image.
    private func fitted(_ rect: CGRect, aspect: CGFloat) -> CGRect {
        var size = rect.size
        if size.width / size.height > aspect { size.width = size.height * aspect } else { size.height = size.width / aspect }
        var result = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        result.origin.x = max(0, min(result.origin.x, pixelSize.width - result.width))
        result.origin.y = max(0, min(result.origin.y, pixelSize.height - result.height))
        return result
    }

    // Image frame inside the view (flipped coordinates).
    private var imageFrame: CGRect {
        let area = bounds.insetBy(dx: 20, dy: 20)
        let scale = min(area.width / pixelSize.width, area.height / pixelSize.height)
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    private var scale: CGFloat { imageFrame.width / pixelSize.width }

    private func toView(_ rect: CGRect) -> CGRect {
        let frame = imageFrame
        return CGRect(x: frame.minX + rect.minX * scale, y: frame.minY + rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    private func toPixel(_ point: CGPoint) -> CGPoint {
        let frame = imageFrame
        return CGPoint(x: min(max((point.x - frame.minX) / scale, 0), pixelSize.width),
                       y: min(max((point.y - frame.minY) / scale, 0), pixelSize.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.blended(withFraction: 0.35, of: .black)?.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let frame = imageFrame
        context.saveGState()
        context.translateBy(x: 0, y: frame.maxY + frame.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: frame)
        context.restoreGState()

        let crop = toView(selection)
        let shade = NSBezierPath(rect: frame)
        shade.appendRect(crop)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        shade.fill()

        NSColor.white.withAlphaComponent(0.35).setStroke()
        for i in 1...2 {
            let x = crop.minX + crop.width * CGFloat(i) / 3
            let y = crop.minY + crop.height * CGFloat(i) / 3
            NSBezierPath.strokeLine(from: CGPoint(x: x, y: crop.minY), to: CGPoint(x: x, y: crop.maxY))
            NSBezierPath.strokeLine(from: CGPoint(x: crop.minX, y: y), to: CGPoint(x: crop.maxX, y: y))
        }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: crop)
        border.lineWidth = 1.5
        border.stroke()
        NSColor.white.setFill()
        for point in handlePoints(crop) {
            NSBezierPath(roundedRect: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10), xRadius: 2, yRadius: 2).fill()
        }
    }

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
         CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let crop = toView(selection)
        startSelection = selection
        let handles = handlePoints(crop)
        if let index = handles.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) < 10 }) {
            // Anchor is the opposite handle; edges only resize one axis.
            let opposite = [3, 2, 1, 0, 5, 4, 7, 6][index]
            let anchor = toPixel(handles[opposite])
            drag = .resize(anchor, horizontal: index != 4 && index != 5, vertical: index != 6 && index != 7)
        } else if crop.contains(point) {
            drag = .move(toPixel(point))
        } else {
            drag = .create(toPixel(point))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = toPixel(convert(event.locationInWindow, from: nil))
        switch drag {
        case .none:
            return
        case .move(let start):
            var rect = startSelection.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            rect.origin.x = max(0, min(rect.origin.x, pixelSize.width - rect.width))
            rect.origin.y = max(0, min(rect.origin.y, pixelSize.height - rect.height))
            selection = rect
        case .resize(let anchor, let horizontal, let vertical):
            var minX = horizontal ? min(anchor.x, point.x) : startSelection.minX
            var maxX = horizontal ? max(anchor.x, point.x) : startSelection.maxX
            var minY = vertical ? min(anchor.y, point.y) : startSelection.minY
            var maxY = vertical ? max(anchor.y, point.y) : startSelection.maxY
            if let aspect {
                let width = maxX - minX, height = maxY - minY
                if !vertical || (horizontal && width / max(height, 1) > aspect) {
                    let h = width / aspect
                    if point.y < anchor.y && vertical { minY = maxY - h } else if vertical { maxY = minY + h } else {
                        minY = startSelection.midY - h / 2; maxY = startSelection.midY + h / 2
                    }
                } else {
                    let w = height * aspect
                    if point.x < anchor.x && horizontal { minX = maxX - w } else if horizontal { maxX = minX + w } else {
                        minX = startSelection.midX - w / 2; maxX = startSelection.midX + w / 2
                    }
                }
            }
            selection = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .intersection(CGRect(origin: .zero, size: pixelSize))
        case .create(let start):
            var rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            if let aspect, rect.width > 0, rect.height > 0 {
                if rect.width / rect.height > aspect { rect.size.height = rect.width / aspect } else { rect.size.width = rect.height * aspect }
                if point.x < start.x { rect.origin.x = start.x - rect.width }
                if point.y < start.y { rect.origin.y = start.y - rect.height }
            }
            selection = rect.intersection(CGRect(origin: .zero, size: pixelSize))
        }
        needsDisplay = true
        onChange?()
    }

    override func mouseUp(with event: NSEvent) {
        if selection.width < 4 || selection.height < 4 { selection = startSelection }
        drag = .none
        needsDisplay = true
        onChange?()
    }

    override func resetCursorRects() {
        addCursorRect(toView(selection), cursor: .openHand)
    }
}
