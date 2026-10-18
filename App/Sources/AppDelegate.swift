import AppKit
import OrbitKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment.shared
        env.start()

        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().delegate = env.jobs

        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        if let index = arguments.firstIndex(of: "--render-promo"), index + 1 < arguments.count {
            let output = URL(fileURLWithPath: arguments[index + 1])
            env.whenReady { PromoRenderer.run(outputDirectory: output, capabilities: env.capabilities) }
            return
        }
        #endif
        if let index = arguments.firstIndex(of: "--demo-wheel") {
            // Developer aid: `Orbit.app/Contents/MacOS/Orbit --demo-wheel file…` shows the wheel for files.
            let files = arguments[(index + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
            let mode = arguments.contains("--tools") ? WheelMode.tools : arguments.contains("--actions") ? .actions : .convert
            env.whenReady {
                let screen = NSScreen.screens.first?.frame ?? .zero
                env.wheel.presentForKeyboard(urls: files, mode: mode, at: CGPoint(x: screen.midX, y: screen.midY))
                #if DEBUG
                if let i = arguments.firstIndex(of: "--hover"), i + 1 < arguments.count { env.wheel.debugHover(arguments[i + 1]) }
                if let i = arguments.firstIndex(of: "--pick"), i + 1 < arguments.count {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { env.wheel.debugActivate(arguments[i + 1]) }
                }
                #endif
            }
        } else if arguments.contains("--settings") {
            SettingsWindowController.shared.show()
        } else if !env.preferences.hasCompletedOnboarding || arguments.contains("--welcome") {
            WelcomeWindowController.shared.show()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // `open -a Orbit file…` or dropping onto the app icon opens the wheel for those files.
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        AppEnvironment.shared.whenReady { AppEnvironment.shared.wheel.presentForKeyboard(urls: files, mode: .convert) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }
}
