import AppKit
import OrbitKit
import ServiceManagement
import SwiftUI

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: WelcomeView(env: AppEnvironment.shared) { [weak self] in self?.close() })
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        AppEnvironment.shared.preferences.hasCompletedOnboarding = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        AppEnvironment.shared.preferences.hasCompletedOnboarding = true
        window = nil
    }
}

/// A sample image users can drag from the welcome window to try the wheel.
enum SampleFile {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orbit", isDirectory: true)
    }

    static func url() -> URL {
        let url = directory.appendingPathComponent("Orbit Sample.png")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 1200, height: 800)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.47, green: 0.40, blue: 0.99, alpha: 1),
                                NSColor(red: 0.13, green: 0.09, blue: 0.38, alpha: 1)])!.draw(in: rect, angle: -50)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: 280, y: 320, width: 640, height: 200))
            ring.lineWidth = 14
            ring.stroke()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: 480, y: 300, width: 240, height: 240)).fill()
            let text = NSAttributedString(string: "Orbit", attributes: [
                .font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.white,
            ])
            text.draw(at: CGPoint(x: 600 - text.size().width / 2, y: 120))
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        return url
    }
}

struct WelcomeView: View {
    @ObservedObject var env: AppEnvironment
    var onDone: () -> Void
    @State private var demo = WelcomeView.makeDemoModel()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let sample = SampleFile.url()

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color(red: 0.47, green: 0.40, blue: 0.99), Color(red: 0.13, green: 0.09, blue: 0.38)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                ZStack {
                    Circle()
                        .fill(.regularMaterial)
                        .frame(width: WheelGeometry.ringOuter * 2, height: WheelGeometry.ringOuter * 2)
                        .position(WheelGeometry.swiftUICenter)
                    WheelView(model: demo)
                }
                .frame(width: WheelGeometry.size.width, height: WheelGeometry.size.height)
                .scaleEffect(0.62)
                .frame(width: WheelGeometry.size.width * 0.62, height: WheelGeometry.size.height * 0.62)
                .allowsHitTesting(false)
            }
            .frame(width: 340)

            VStack(alignment: .leading, spacing: 18) {
                Text("Welcome to Orbit")
                    .font(.system(size: 28, weight: .bold))
                Text("Convert, compress and share files right where they are — no app to open, nothing uploaded.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Start dragging any file.")
                    step(2, "Tap \(env.preferences.convertKey.symbol) to convert, \(env.preferences.toolsKey.symbol) for tools, \(env.preferences.actionsKey.symbol) for actions.")
                    step(3, "Drop it on a slice. The result appears next to the original.")
                }

                HStack(spacing: 12) {
                    Image(nsImage: NSImage(contentsOf: sample) ?? NSImage())
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Try it: drag this picture").font(.system(size: 13, weight: .semibold))
                        Text("…then tap \(env.preferences.convertKey.symbol) while dragging").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "hand.draw").foregroundColor(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .onDrag { NSItemProvider(contentsOf: sample) ?? NSItemProvider() }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Other ways in").font(.system(size: 12, weight: .semibold))
                    Text("• Drop files on the menu bar icon\n• Select files in Finder and press \(env.preferences.hotKeyPreset.title)\n• Right-click › Quick Actions › Open in Orbit")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack {
                    Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }))
                    Spacer()
                    Button("Get Started", action: onDone)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
            }
            .padding(28)
            .padding(.top, 10)
        }
        .frame(width: 760, height: 520)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor
    private static func makeDemoModel() -> WheelModel {
        let model = WheelModel()
        let selection = FileSelection(urls: [URL(fileURLWithPath: "/demo/photo.heic")])
        let caps = Capabilities(ffmpeg: nil, cwebp: URL(fileURLWithPath: "/usr/bin/true"), libreOffice: nil,
                                iwork: IWork(pages: false, keynote: false, numbers: false),
                                imageIOWritableTypes: ["public.avif"])
        model.nodes = Catalog.convertMenu(for: selection, capabilities: caps)
        model.summary = SelectionSummary(icon: NSWorkspace.shared.icon(for: .heic), title: "photo.heic", subtitle: "HEIC image")
        model.hit = .slice(0)
        model.shown = true
        return model
    }
}
