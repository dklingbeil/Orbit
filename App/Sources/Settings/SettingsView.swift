import AppKit
import OrbitKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Orbit Settings"
        window.contentView = NSHostingView(rootView: SettingsView(env: AppEnvironment.shared, preferences: AppEnvironment.shared.preferences))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct SettingsView: View {
    @ObservedObject var env: AppEnvironment
    @ObservedObject var preferences: Preferences

    var body: some View {
        TabView {
            GeneralSettings(preferences: preferences)
                .tabItem { Label("General", systemImage: "gearshape") }
            OutputSettings(preferences: preferences)
                .tabItem { Label("Output", systemImage: "folder") }
            QualitySettings(preferences: preferences)
                .tabItem { Label("Quality", systemImage: "slider.horizontal.3") }
            EngineSettingsView(env: env, preferences: preferences)
                .tabItem { Label("Engines", systemImage: "cpu") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open the wheel while dragging files", isOn: $preferences.dragGestureEnabled)
                Picker("Open it by", selection: $preferences.triggerStyle) {
                    ForEach(TriggerStyle.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!preferences.dragGestureEnabled)
            }
            Section("Keys") {
                keyPicker("Convert", selection: $preferences.convertKey)
                keyPicker("Tools", selection: $preferences.toolsKey)
                keyPicker("Actions", selection: $preferences.actionsKey)
                if Set([preferences.convertKey, preferences.toolsKey, preferences.actionsKey]).count < 3 {
                    Text("Each wheel needs its own key.").font(.caption).foregroundColor(.orange)
                }
                Picker("Finder selection shortcut", selection: $preferences.hotKeyPreset) {
                    ForEach(HotKeyPreset.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle("Launch Orbit at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError { Text(loginError).font(.caption).foregroundColor(.orange) }
                Picker("Terminal app", selection: $preferences.terminalBundleID) {
                    ForEach(FileActions.installedTerminals, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func keyPicker(_ title: String, selection: Binding<ModifierKey>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModifierKey.allCases) { Text("\($0.symbol)  \($0.name)").tag($0) }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct OutputSettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("Save results") {
                Picker("Location", selection: $preferences.outputLocation) {
                    ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
                }
                if preferences.outputLocation == .custom {
                    HStack {
                        Text(preferences.customOutputPath.isEmpty ? "No folder chosen" : preferences.customOutputPath)
                            .lineLimit(1).truncationMode(.middle).foregroundColor(.secondary)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Text("Originals are never changed. If a name is taken, Orbit adds a number.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("When done") {
                Toggle("Reveal results in Finder", isOn: $preferences.revealInFinder)
                Toggle("Play a sound", isOn: $preferences.playSound)
                Toggle("Notify me when long tasks finish", isOn: $preferences.notifyWhenDone)
                Toggle("Copy recognized text to the clipboard", isOn: $preferences.copyRecognizedText)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { preferences.customOutputPath = url.path }
    }
}

private struct QualitySettings: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("Images") {
                HStack {
                    Slider(value: $preferences.imageQuality, in: 0.5...1, step: 0.05) { Text("Quality") }
                    Text("\(Int(preferences.imageQuality * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Toggle("Keep photo metadata (camera, date, location)", isOn: $preferences.keepMetadata)
            }
            Section("PDF") {
                Picker("Page images resolution", selection: $preferences.pdfDPI) {
                    Text("150 dpi").tag(150.0)
                    Text("300 dpi").tag(300.0)
                    Text("600 dpi").tag(600.0)
                }
            }
            Section("Video") {
                Picker("Encoder", selection: $preferences.preferHardwareVideo) {
                    Text("Fast (hardware)").tag(true)
                    Text("Smaller files (software)").tag(false)
                }
                Text("Hardware encoding uses Apple silicon's media engine. Software encoding (x264) is slower but more efficient.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct EngineSettingsView: View {
    @ObservedObject var env: AppEnvironment
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("Detected") {
                ForEach(env.capabilities.summary, id: \.0) { name, value in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: isMissing(value) ? "xmark.circle" : "checkmark.circle.fill")
                            .foregroundColor(isMissing(value) ? .secondary : .green)
                        Text(name)
                        Spacer()
                        Text(value).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
            }
            Section("FFmpeg") {
                HStack {
                    TextField("Custom ffmpeg path (optional)", text: $preferences.ffmpegPath)
                    Button("Re-scan") { env.refreshCapabilities() }
                }
                Text("Audio and video need FFmpeg. Release builds of Orbit bundle it; otherwise install it with `brew install ffmpeg`. Office slides and old .xls/.doc files use LibreOffice (`brew install --cask libreoffice`) or Keynote/Numbers.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func isMissing(_ value: String) -> Bool {
        value.hasPrefix("Not") || value.hasPrefix("Requires")
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Orbit").font(.system(size: 22, weight: .bold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundColor(.secondary)
            Text("Drag a file. Tap a key. Drop it on a format.\nEverything runs on your Mac — nothing is uploaded.")
                .multilineTextAlignment(.center)
                .font(.callout)
            Text("Open source under the MIT License.").font(.caption).foregroundColor(.secondary)
            if let credits = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
                Button("Third-Party Notices") { NSWorkspace.shared.open(credits) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
