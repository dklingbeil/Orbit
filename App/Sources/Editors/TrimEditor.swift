import AppKit
import AVFoundation
import AVKit
import OrbitKit

/// Lets the user pick a start and end time, using AVKit's native trimming UI when possible.
@MainActor
final class TrimEditor: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<ClosedRange<Double>?, Never>?
    private static var current: TrimEditor?

    static func run(for url: URL, ffmpeg: FFmpeg?) async -> ClosedRange<Double>? {
        NSApp.activate(ignoringOtherApps: true)
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        if playable, duration > 0 {
            let editor = TrimEditor()
            current = editor
            let result = await editor.present(asset: asset, url: url)
            current = nil
            return result
        }
        // Formats AVFoundation can't play (MKV, WebM, AVI…): ask for times.
        let total = (try? await ffmpeg?.probe(url))?.duration ?? 0
        return manualRange(for: url, duration: total)
    }

    private func present(asset: AVURLAsset, url: URL) async -> ClosedRange<Double>? {
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false

        var size = CGSize(width: 760, height: 460)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
            let oriented = natural.applying(transform)
            let ratio = abs(oriented.width) / max(abs(oriented.height), 1)
            size = ratio >= 1 ? CGSize(width: 760, height: 760 / ratio + 70) : CGSize(width: 460 * ratio, height: 530)
        } else {
            size = CGSize(width: 600, height: 160)
        }

        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Trim “\(url.lastPathComponent)”"
        window.contentView = playerView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            // Trimming can begin once the item is ready.
            Task { @MainActor in
                var attempts = 0
                while item.status != .readyToPlay, attempts < 60 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    attempts += 1
                }
                guard playerView.canBeginTrimming else {
                    self.finish(nil)
                    return
                }
                let result = await playerView.beginTrimming()
                guard result == .okButton else {
                    self.finish(nil)
                    return
                }
                let start = item.reversePlaybackEndTime.isValid ? CMTimeGetSeconds(item.reversePlaybackEndTime) : 0
                let end = item.forwardPlaybackEndTime.isValid ? CMTimeGetSeconds(item.forwardPlaybackEndTime) : CMTimeGetSeconds(item.duration)
                self.finish(start < end ? start...end : nil)
            }
        }
    }

    private func finish(_ range: ClosedRange<Double>?) {
        guard let continuation else { return }
        self.continuation = nil
        (window?.contentView as? AVPlayerView)?.player?.pause()
        window?.delegate = nil
        window?.close()
        continuation.resume(returning: range)
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    private static func manualRange(for url: URL, duration: Double) -> ClosedRange<Double>? {
        let alert = NSAlert()
        alert.messageText = "Trim “\(url.lastPathComponent)”"
        alert.informativeText = duration > 0 ? "Length: \(Timecode.format(duration)). Enter the part to keep." : "Enter the part to keep."
        alert.addButton(withTitle: "Trim")
        alert.addButton(withTitle: "Cancel")
        let start = NSTextField(string: "0:00")
        let end = NSTextField(string: duration > 0 ? Timecode.format(duration) : "")
        start.placeholderString = "Start (e.g. 0:05)"
        end.placeholderString = "End (e.g. 1:30)"
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Start"), start], [NSTextField(labelWithString: "End"), end]])
        grid.column(at: 1).width = 180
        grid.frame = CGRect(x: 0, y: 0, width: 240, height: 56)
        alert.accessoryView = grid
        alert.window.initialFirstResponder = start
        guard alert.runModal() == .alertFirstButtonReturn,
              let s = Timecode.parseDuration(start.stringValue),
              let e = Timecode.parseDuration(end.stringValue), e > s else { return nil }
        return s...e
    }
}
