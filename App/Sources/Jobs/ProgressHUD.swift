import AppKit
import SwiftUI

/// Floating card near the pointer that shows running jobs, results and short confirmations.
@MainActor
final class ProgressHUD: ObservableObject {
    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let symbol: String
        let reveal: [URL]
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var toasts: [Toast] = []
    @Published var hovering = false

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var anchor: NSPoint?

    func show(jobs newJobs: [Job]) {
        jobs = (newJobs + jobs.filter { $0.isActive || ($0.finishedAt.map { Date().timeIntervalSince($0) < 4 } ?? false) })
        jobs = Array(jobs.prefix(6))
        anchor = NSEvent.mouseLocation
        present()
    }

    func toast(_ message: String, symbol: String, reveal: [URL] = []) {
        toasts.append(Toast(message: message, symbol: symbol, reveal: reveal))
        if anchor == nil || jobs.allSatisfy({ !$0.isActive }) { anchor = NSEvent.mouseLocation }
        present()
        let id = toasts.last!.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let toast = self.toasts.first(where: { $0.id == id }) else { return }
            if self.hovering { return self.scheduleHideIfIdle() }
            self.dismiss(toast)
        }
    }

    func jobsChanged() {
        objectWillChange.send()
        // A finished row can be taller than a progress bar (e.g. an error message); re-measure.
        DispatchQueue.main.async { [weak self] in self?.resize() }
        scheduleHideIfIdle()
    }

    func dismiss(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        if jobs.isEmpty && toasts.isEmpty { hideNow() } else { resize(); scheduleHideIfIdle() }
    }

    func dismiss(_ toast: Toast) {
        toasts.removeAll { $0.id == toast.id }
        if jobs.isEmpty && toasts.isEmpty { hideNow() } else { resize(); scheduleHideIfIdle() }
    }

    private func hideNow() {
        hideWorkItem?.cancel()
        panel?.orderOut(nil)
        jobs = []
        toasts = []
        anchor = nil
        hovering = false
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        resize()
        panel.orderFrontRegardless()
        hideWorkItem?.cancel()
        scheduleHideIfIdle()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 80),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HUDView(hud: self))
        host.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = host
        self.panel = panel
        return panel
    }

    func resize() {
        guard let panel, let host = panel.contentView as? NSHostingView<HUDView> else { return }
        let size = host.fittingSize
        let point = anchor ?? NSEvent.mouseLocation
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height - 36)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    func scheduleHideIfIdle() {
        hideWorkItem?.cancel()
        let busy = jobs.contains(where: \.isActive) || !toasts.isEmpty
        guard !busy else { return }
        let failed = jobs.contains { if case .failed = $0.state { return true }; return false }
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering else { self?.scheduleHideIfIdle(); return }
            self.hideNow()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (failed ? 4.5 : 2), execute: item)
    }
}

struct HUDView: View {
    @ObservedObject var hud: ProgressHUD

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(hud.jobs) { job in
                JobRow(job: job, hud: hud)
            }
            ForEach(hud.toasts) { toast in
                HStack(spacing: 8) {
                    Image(systemName: toast.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 22)
                    Text(toast.message)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !toast.reveal.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(toast.reveal) }
                    hud.dismiss(toast)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        )
        .padding(14)
        .onHover { hud.hovering = $0 }
        .onChange(of: hud.jobs.count) { _ in DispatchQueue.main.async { hud.resize() } }
        .onChange(of: hud.toasts.count) { _ in DispatchQueue.main.async { hud.resize() } }
    }
}

struct JobRow: View {
    @ObservedObject var job: Job
    let hud: ProgressHUD

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: job.icon)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                status
            }
            Spacer(minLength: 4)
            trailing
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Click to reveal a result, or to dismiss a finished or failed card.
            if !job.outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }
            if !job.isActive { hud.dismiss(job) }
        }
        .help(helpText)
    }

    private var helpText: String {
        switch job.state {
        case .done: return "Show in Finder"
        case .failed(let message): return message
        default: return job.name
        }
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .queued:
            Text("Waiting · \(job.name)").font(.system(size: 10.5)).foregroundColor(.secondary).lineLimit(1)
        case .running:
            if let progress = job.progress {
                ProgressView(value: progress).progressViewStyle(.linear).controlSize(.small)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            }
        case .done(let outputs):
            Text(outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files")
                .font(.system(size: 10.5)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
        case .failed(let message):
            Text(message).font(.system(size: 10.5)).foregroundColor(.orange).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled:
            Text("Cancelled").font(.system(size: 10.5)).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch job.state {
        case .queued, .running:
            Button { job.cancel() } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundColor(.secondary)
        }
    }
}
