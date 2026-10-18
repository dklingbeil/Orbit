import AppKit
import Combine
import OrbitKit

/// Owns the app's long-lived services and wires them together.
@MainActor
final class AppEnvironment: ObservableObject {
    static let shared = AppEnvironment()

    let preferences = Preferences.shared
    @Published private(set) var capabilities = Capabilities(ffmpeg: nil, cwebp: nil, libreOffice: nil,
                                                            iwork: IWork(pages: false, keynote: false, numbers: false),
                                                            imageIOWritableTypes: [])
    @Published private(set) var capabilitiesReady = false

    private(set) lazy var jobs = JobManager(env: self)
    private(set) lazy var wheel = WheelController(env: self)
    private(set) lazy var dragMonitor = DragMonitor()
    private(set) lazy var statusItem = StatusItemController(env: self)

    private var hotKey: HotKey?
    private var readyCallbacks: [() -> Void] = []
    private var cancellables: Set<AnyCancellable> = []

    func start() {
        statusItem.install()
        refreshCapabilities()

        dragMonitor.modeForModifier = { [unowned self] flag in self.preferences.mode(for: flag) }
        dragMonitor.onTrigger = { [unowned self] mode, payload, location in
            if self.wheel.isVisible {
                self.wheel.switchMode(mode)
            } else {
                self.wheel.presentForDrag(payload: payload, mode: mode, at: location)
            }
        }
        dragMonitor.onDragEnded = { [unowned self] in self.wheel.dragEnded() }

        preferences.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [unowned self] _ in self.applyPreferences() }
            .store(in: &cancellables)
        applyPreferences()
    }

    func applyPreferences() {
        dragMonitor.isEnabled = preferences.dragGestureEnabled
        dragMonitor.triggerOnPress = preferences.triggerStyle == .press
        dragMonitor.watchedModifiers = preferences.watchedModifiers

        if hotKey?.preset != preferences.hotKeyPreset {
            hotKey = nil
            if let preset = preferences.hotKeyPreset.binding {
                hotKey = HotKey(preset: preferences.hotKeyPreset, keyCode: preset.keyCode, modifiers: preset.modifiers) { [weak self] in
                    self?.openFinderSelection()
                }
            }
        }
    }

    func refreshCapabilities() {
        let override = preferences.ffmpegPath.isEmpty ? nil : preferences.ffmpegPath
        Task.detached(priority: .userInitiated) {
            let detected = Capabilities.detect(ffmpegPath: override)
            await MainActor.run {
                self.capabilities = detected
                self.capabilitiesReady = true
                let callbacks = self.readyCallbacks
                self.readyCallbacks = []
                callbacks.forEach { $0() }
            }
        }
    }

    /// Runs `work` once engine detection has finished (immediately if it already has).
    func whenReady(_ work: @escaping () -> Void) {
        if capabilitiesReady { work() } else { readyCallbacks.append(work) }
    }

    var engineSettings: EngineSettings {
        var settings = EngineSettings()
        settings.imageQuality = preferences.imageQuality
        settings.pdfRenderDPI = preferences.pdfDPI
        settings.preferHardwareVideo = preferences.preferHardwareVideo
        settings.preserveImageMetadata = preferences.keepMetadata
        return settings
    }

    /// Keyboard path: open the wheel for whatever is selected in Finder.
    func openFinderSelection() {
        let urls = FinderSelection.current()
        if urls.isEmpty {
            openFilesPanel()
        } else {
            wheel.presentForKeyboard(urls: urls, mode: .convert)
        }
    }

    func openFilesPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        panel.message = "Choose files to convert"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        wheel.presentForKeyboard(urls: panel.urls, mode: .convert)
    }
}
