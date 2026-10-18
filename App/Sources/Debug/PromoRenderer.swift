#if DEBUG
import AppKit
import OrbitKit
import SwiftUI

/// Renders the README visuals offscreen from the real wheel views (no screen capture involved).
/// Run via `scripts/make-promo.sh`, which turns the frames into docs/demo.gif.
@MainActor
enum PromoRenderer {
    static let canvas = CGSize(width: 1200, height: 750)
    static let wheelCenter = CGPoint(x: 600, y: 410)
    static let fps = 25.0

    struct Frame {
        var cursor: CGPoint
        var dragOpacity: Double = 1
        var dragScale: CGFloat = 1
        var wheelAppear: Double = 0
        var wheelOpacity: Double = 0
        var keycap: Double = 0
        var keyPressed = false
        var hud: Double = 0
        /// Where the dragged photo sits relative to the cursor tip.
        var dragOffset = CGSize(width: 58, height: 54)
    }

    static func run(outputDirectory: URL, capabilities: Capabilities) {
        let fm = FileManager.default
        try? fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let framesDirectory = outputDirectory.appendingPathComponent("frames", isDirectory: true)
        try? fm.removeItem(at: framesDirectory)
        try? fm.createDirectory(at: framesDirectory, withIntermediateDirectories: true)

        let photo = makePhoto()
        let photoURL = fm.temporaryDirectory.appendingPathComponent("photo.heic")
        let webpURL = fm.temporaryDirectory.appendingPathComponent("photo.webp")
        for url in [photoURL, webpURL] where !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: Data()) }

        // Convert wheel for a HEIC photo.
        let model = WheelModel()
        model.solidBackgrounds = true
        model.shown = true
        model.nodes = Catalog.convertMenu(for: FileSelection(urls: [photoURL]), capabilities: capabilities)
        model.summary = SelectionSummary(icon: NSWorkspace.shared.icon(for: .heic), title: "photo.heic", subtitle: "HEIC image")
        let webpIndex = model.nodes.firstIndex { $0.title == "WebP" } ?? 2
        let pngIndex = model.nodes.firstIndex { $0.title == "PNG" } ?? 1

        let job = Job(title: "Convert to WebP", inputs: [photoURL])
        job.state = .done([webpURL])

        // Timeline
        let total = 4.8
        let start = CGPoint(x: 230, y: 640)
        let pngPoint = point(onSlice: pngIndex, count: model.nodes.count, radius: 104)
        let webpPoint = point(onSlice: webpIndex, count: model.nodes.count, radius: 112)
        var index = 0
        var time = 0.0
        while time < total {
            var frame = Frame(cursor: start)
            // 1. Drag the photo in.
            let approach = ease(progress(time, 0.0, 0.9))
            frame.cursor = lerp(start, wheelCenter, approach)
            // 2. Tap ⇧.
            frame.keycap = min(progress(time, 0.5, 0.7), 1 - progress(time, 1.45, 1.65))
            frame.keyPressed = time >= 0.8 && time < 0.97
            // 3. The wheel opens.
            frame.wheelAppear = ease(progress(time, 0.95, 1.2))
            frame.wheelOpacity = frame.wheelAppear
            // 4. Move over PNG to WebP.
            if time >= 1.3 {
                let t = ease(progress(time, 1.3, 2.25))
                frame.cursor = quadratic(wheelCenter, CGPoint(x: pngPoint.x + 10, y: pngPoint.y - 20), webpPoint, t)
            }
            // 5. Drop.
            let drop = progress(time, 2.75, 2.95)
            if time >= 2.75 {
                frame.dragOpacity = 1 - drop
                frame.dragScale = 1 - 0.4 * drop
                frame.wheelOpacity = 1 - drop
                frame.wheelAppear = 1 - 0.06 * drop
            }
            // 6. Done.
            frame.hud = ease(progress(time, 2.95, 3.3))

            let hit = WheelGeometry.hit(wheelLocal(frame.cursor), sliceCount: model.nodes.count, expanded: nil, childCount: 0, tabFrames: [:])
            model.hit = time < 1.3 ? .none : hit

            let view = PromoScene(model: model, frame: frame, photo: photo, job: job)
            write(view, to: framesDirectory.appendingPathComponent(String(format: "frame-%03d.png", index)), scale: 1)
            index += 1
            time += 1 / fps
        }

        // Still: the Tools wheel with the Compress options open.
        let tools = WheelModel()
        tools.solidBackgrounds = true
        tools.shown = true
        tools.mode = .tools
        tools.nodes = Catalog.toolsMenu(for: FileSelection(urls: [photoURL]), capabilities: capabilities)
        tools.summary = model.summary
        if let compress = tools.nodes.firstIndex(where: { $0.title == "Compress" }) {
            tools.expanded = compress
            tools.hit = .child(1)
        }
        var still = Frame(cursor: CGPoint(x: wheelCenter.x + 22, y: wheelCenter.y - 182), wheelAppear: 1, wheelOpacity: 1)
        still.dragOffset = CGSize(width: 100, height: -14)
        write(PromoScene(model: tools, frame: still, photo: photo, job: job, showDrag: true),
              to: outputDirectory.appendingPathComponent("tools.png"), scale: 2)

        print("Rendered \(index) frames to \(framesDirectory.path)")
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    static func wheelLocal(_ point: CGPoint) -> CGPoint {
        // Canvas (y-down) → wheel view AppKit coordinates (y-up).
        let originX = wheelCenter.x - WheelGeometry.swiftUICenter.x
        let originY = wheelCenter.y - WheelGeometry.swiftUICenter.y
        return CGPoint(x: point.x - originX, y: WheelGeometry.size.height - (point.y - originY))
    }

    static func point(onSlice index: Int, count: Int, radius: CGFloat) -> CGPoint {
        let degrees = WheelGeometry.sliceCenterAngle(index, count: count) * .pi / 180
        return CGPoint(x: wheelCenter.x + radius * sin(degrees), y: wheelCenter.y - radius * cos(degrees))
    }

    static func progress(_ t: Double, _ from: Double, _ to: Double) -> Double { min(1, max(0, (t - from) / (to - from))) }
    static func ease(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    static func quadratic(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        lerp(lerp(a, c, t), lerp(c, b, t), t)
    }

    static func write<V: View>(_ view: V, to url: URL, scale: CGFloat) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = scale
        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// A small landscape "photo" to drag around.
    static func makePhoto() -> NSImage {
        NSImage(size: NSSize(width: 360, height: 240), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 1, green: 0.72, blue: 0.45, alpha: 1), NSColor(red: 0.45, green: 0.55, blue: 0.95, alpha: 1)])!
                .draw(in: rect, angle: 90)
            NSColor(red: 1, green: 0.93, blue: 0.75, alpha: 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: 230, y: 120, width: 60, height: 60)).fill()
            let far = NSBezierPath()
            far.move(to: CGPoint(x: 0, y: 70)); far.line(to: CGPoint(x: 90, y: 150)); far.line(to: CGPoint(x: 170, y: 90))
            far.line(to: CGPoint(x: 260, y: 160)); far.line(to: CGPoint(x: 360, y: 80)); far.line(to: CGPoint(x: 360, y: 0)); far.line(to: .zero)
            NSColor(red: 0.33, green: 0.32, blue: 0.62, alpha: 1).setFill()
            far.fill()
            let near = NSBezierPath()
            near.move(to: CGPoint(x: 0, y: 40)); near.curve(to: CGPoint(x: 360, y: 55), controlPoint1: CGPoint(x: 120, y: 95), controlPoint2: CGPoint(x: 240, y: 10))
            near.line(to: CGPoint(x: 360, y: 0)); near.line(to: .zero)
            NSColor(red: 0.18, green: 0.2, blue: 0.42, alpha: 1).setFill()
            near.fill()
            return true
        }
    }
}

/// One frame: desktop, menu bar, the wheel, the dragged photo, a keycap hint and the result card.
private struct PromoScene: View {
    @ObservedObject var model: WheelModel
    let frame: PromoRenderer.Frame
    let photo: NSImage
    let job: Job
    var showDrag = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            wallpaper
            menuBar

            // Wheel
            ZStack {
                Circle()
                    .fill(Color(white: 0.11).opacity(0.94))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    .frame(width: (WheelGeometry.ringOuter + 6) * 2, height: (WheelGeometry.ringOuter + 6) * 2)
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
                    .position(WheelGeometry.swiftUICenter)
                WheelView(model: model)
            }
            .frame(width: WheelGeometry.size.width, height: WheelGeometry.size.height)
            .scaleEffect(0.82 + 0.18 * frame.wheelAppear, anchor: UnitPoint(x: WheelGeometry.swiftUICenter.x / WheelGeometry.size.width,
                                                                          y: WheelGeometry.swiftUICenter.y / WheelGeometry.size.height))
            .opacity(frame.wheelOpacity)
            .position(x: PromoRenderer.wheelCenter.x, y: PromoRenderer.wheelCenter.y - WheelGeometry.swiftUICenter.y + WheelGeometry.size.height / 2)

            // Result card
            resultCard
                .opacity(frame.hud)
                .offset(y: 12 * (1 - frame.hud))
                .position(x: PromoRenderer.wheelCenter.x + 150, y: PromoRenderer.wheelCenter.y + 70)

            // Keycap hint
            keycap
                .opacity(frame.keycap)
                .position(x: canvasWidth / 2, y: 690)

            // Dragged photo + cursor
            if showDrag {
                VStack(spacing: 4) {
                    Image(nsImage: photo)
                        .resizable()
                        .frame(width: 96, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
                    Text("photo.heic")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                }
                .opacity(0.88 * frame.dragOpacity)
                .scaleEffect(frame.dragScale)
                .position(x: frame.cursor.x + frame.dragOffset.width, y: frame.cursor.y + frame.dragOffset.height)

                Image(nsImage: NSCursor.arrow.image)
                    .position(x: frame.cursor.x + NSCursor.arrow.image.size.width / 2 - NSCursor.arrow.hotSpot.x,
                              y: frame.cursor.y + NSCursor.arrow.image.size.height / 2 - NSCursor.arrow.hotSpot.y)
            }
        }
        .frame(width: PromoRenderer.canvas.width, height: PromoRenderer.canvas.height)
        .clipped()
    }

    private var canvasWidth: CGFloat { PromoRenderer.canvas.width }

    private var wallpaper: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.42), Color(red: 0.05, green: 0.05, blue: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.55, green: 0.35, blue: 0.95).opacity(0.55), .clear], center: UnitPoint(x: 0.2, y: 0.25),
                           startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.6).opacity(0.35), .clear], center: UnitPoint(x: 0.85, y: 0.8),
                           startRadius: 0, endRadius: 480)
        }
        .frame(width: PromoRenderer.canvas.width, height: PromoRenderer.canvas.height)
    }

    private var menuBar: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
            Text("Finder").font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            Image(nsImage: tinted(StatusIcon.make()))
            Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
            Image(systemName: "battery.75percent").font(.system(size: 15))
            Text("Sat 9:41").font(.system(size: 13, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 18)
        .frame(width: PromoRenderer.canvas.width, height: 30)
        .background(Color.black.opacity(0.28))
    }

    private var keycap: some View {
        HStack(spacing: 12) {
            Text("⇧")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundColor(frame.keyPressed ? .white : Color(white: 0.15))
                .frame(width: 86, height: 50)
                .background(RoundedRectangle(cornerRadius: 9).fill(frame.keyPressed ? Color.accentColor : Color(white: 0.93)))
                .shadow(color: .black.opacity(frame.keyPressed ? 0.15 : 0.4), radius: frame.keyPressed ? 1 : 4, y: frame.keyPressed ? 1 : 4)
                .scaleEffect(frame.keyPressed ? 0.93 : 1)
            Text("Tap Shift while dragging")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var resultCard: some View {
        JobRow(job: job, hud: ProgressHUD())
            .padding(12)
            .frame(width: 280)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.16))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6))
    }

    private func tinted(_ image: NSImage) -> NSImage {
        let copy = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return copy
    }
}
#endif
