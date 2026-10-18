import AppKit
import OrbitKit
@preconcurrency import UserNotifications

@MainActor
final class Job: ObservableObject, Identifiable {
    enum State: Equatable {
        case queued, running, done([URL]), failed(String), cancelled
    }

    let id = UUID()
    let title: String
    let inputs: [URL]
    let icon: NSImage
    let startedAt = Date()
    @Published var progress: Double?
    @Published var state: State = .queued
    var task: Task<Void, Never>?
    var finishedAt: Date?

    init(title: String, inputs: [URL]) {
        self.title = title
        self.inputs = inputs
        self.icon = NSWorkspace.shared.icon(forFile: inputs.first?.path ?? "/")
    }

    var name: String { inputs.count == 1 ? inputs[0].lastPathComponent : "\(inputs.count) files" }

    var isActive: Bool { state == .queued || state == .running }

    var outputs: [URL] {
        if case .done(let urls) = state { return urls }
        return []
    }

    func cancel() { task?.cancel() }
}

/// Limits concurrent work: media encodes are heavy, everything else is light.
actor JobLimiter {
    private var running: [Bool: Int] = [:]
    private var waiting: [(heavy: Bool, continuation: CheckedContinuation<Void, Never>)] = []

    private func limit(_ heavy: Bool) -> Int {
        heavy ? 2 : max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    func acquire(heavy: Bool) async {
        if running[heavy, default: 0] < limit(heavy) {
            running[heavy, default: 0] += 1
            return
        }
        await withCheckedContinuation { waiting.append((heavy, $0)) }
    }

    func release(heavy: Bool) {
        if let index = waiting.firstIndex(where: { $0.heavy == heavy }) {
            waiting.remove(at: index).continuation.resume()
        } else {
            running[heavy, default: 1] -= 1
        }
    }
}

@MainActor
final class JobManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var jobs: [Job] = []
    let hud = ProgressHUD()
    private unowned let env: AppEnvironment
    private let limiter = JobLimiter()

    init(env: AppEnvironment) {
        self.env = env
        super.init()
    }

    var activeCount: Int { jobs.filter(\.isActive).count }

    func run(_ spec: OperationSpec, inputs: [URL], parameters: OperationParameters, title: String) {
        let groups: [[URL]] = spec.isCombined ? [inputs] : inputs.map { [$0] }
        var started: [Job] = []
        for group in groups {
            if case .convert(let format) = spec.kind, FormatDetector.format(for: group[0]) == format { continue }
            let job = Job(title: title, inputs: group)
            jobs.insert(job, at: 0)
            started.append(job)
            job.task = Task { [weak self] in await self?.execute(job, spec: spec, parameters: parameters) }
        }
        if jobs.count > 40 { jobs.removeLast(jobs.count - 40) }
        if !started.isEmpty { hud.show(jobs: started) }
    }

    private func isHeavy(_ spec: OperationSpec, inputs: [URL]) -> Bool {
        let category = inputs.first.flatMap(FormatDetector.format(for:))?.category
        if category == .video || category == .audio { return true }
        if case .convert(let format) = spec.kind, format.category == .video { return true }
        return false
    }

    private func execute(_ job: Job, spec: OperationSpec, parameters: OperationParameters) async {
        let heavy = isHeavy(spec, inputs: job.inputs)
        await limiter.acquire(heavy: heavy)
        defer { Task { await limiter.release(heavy: heavy) } }
        guard !Task.isCancelled else {
            job.state = .cancelled
            return
        }

        job.state = .running
        let destination = env.preferences.outputDirectory(for: job.inputs)
        let context: JobContext
        let workDirectory: URL
        do {
            workDirectory = try OutputNaming.makeWorkDirectory(near: destination)
            context = JobContext(workDirectory: workDirectory, capabilities: env.capabilities, settings: env.engineSettings,
                                 parameters: parameters) { [weak job] value in
                Task { @MainActor in job?.progress = value }
            }
        } catch {
            finish(job, state: .failed(error.localizedDescription))
            return
        }

        do {
            let produced = try await OperationRunner.run(spec, inputs: job.inputs, context: context)
            let placed = try OutputNaming.place(produced, into: destination)
            try? FileManager.default.removeItem(at: workDirectory)
            finish(job, state: .done(placed))
            afterSuccess(job, spec: spec, outputs: placed)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: workDirectory)
            finish(job, state: .cancelled)
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            finish(job, state: Task.isCancelled ? .cancelled : .failed(error.localizedDescription))
        }
    }

    private func finish(_ job: Job, state: Job.State) {
        job.state = state
        job.finishedAt = Date()
        job.progress = 1
        hud.jobsChanged()
        objectWillChange.send()

        let duration = Date().timeIntervalSince(job.startedAt)
        if case .failed = state, env.preferences.playSound { NSSound(named: "Basso")?.play() }
        if env.preferences.notifyWhenDone, duration > 8, !NSApp.isActive {
            notify(job, state: state)
        }
        if case .failed = state { return }
        if activeCount == 0, env.preferences.playSound, case .done = state {
            NSSound(named: "Pop")?.play()
        }
    }

    private func afterSuccess(_ job: Job, spec: OperationSpec, outputs: [URL]) {
        if case .tool(.imageExtractText) = spec.kind, env.preferences.copyRecognizedText,
           let text = outputs.compactMap({ try? String(contentsOf: $0, encoding: .utf8) }).first {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            hud.toast("Recognized text copied", symbol: "text.viewfinder", reveal: outputs)
        }
        if job.inputs.contains(where: { $0.path.hasPrefix(SampleFile.directory.path) }) {
            // Results of the onboarding sample land in Downloads; show them.
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        } else if env.preferences.revealInFinder, activeCount == 0 {
            NSWorkspace.shared.activateFileViewerSelecting(jobs.filter { !$0.isActive && $0.finishedAt.map { Date().timeIntervalSince($0) < 5 } == true }
                .flatMap(\.outputs))
        }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    // MARK: Notifications

    private func notify(_ job: Job, state: Job.State) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                let content = UNMutableNotificationContent()
                switch state {
                case .done(let outputs):
                    content.title = "Done: \(job.title)"
                    content.body = outputs.map(\.lastPathComponent).joined(separator: ", ")
                    content.userInfo = ["paths": outputs.map(\.path)]
                case .failed(let message):
                    content.title = "Couldn't finish: \(job.title)"
                    content.body = message
                default:
                    return
                }
                center.add(UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil))
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        DispatchQueue.main.async {
            if !paths.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
