import AppKit
import OrbitKit
import UniformTypeIdentifiers

enum WheelMode: Int, CaseIterable, Identifiable {
    case convert, tools, actions

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }
    var next: WheelMode { WheelMode(rawValue: (rawValue + 1) % 3)! }
    var previous: WheelMode { WheelMode(rawValue: (rawValue + 2) % 3)! }
}

/// Shared layout math, so drawing (SwiftUI, y-down) and hit-testing (AppKit, y-up) agree.
enum WheelGeometry {
    static let size = CGSize(width: 500, height: 540)
    /// Center in AppKit coordinates (origin bottom-left).
    static let center = CGPoint(x: 250, y: 240)
    /// Center in SwiftUI coordinates (origin top-left).
    static var swiftUICenter: CGPoint { CGPoint(x: center.x, y: size.height - center.y) }

    static let hubRadius: CGFloat = 58
    static let ringInner: CGFloat = 64
    static let ringOuter: CGFloat = 152
    static let childInner: CGFloat = 158
    static let childOuter: CGFloat = 214
    static let tabsTop: CGFloat = 18          // from the top edge, SwiftUI coordinates
    static let tabsHeight: CGFloat = 30
    static let gapDegrees: CGFloat = 1.2

    enum Hit: Equatable {
        case none, hub, slice(Int), child(Int), tab(WheelMode)
    }

    static func step(_ count: Int) -> CGFloat { 360 / CGFloat(max(count, 1)) }

    /// Degrees clockwise from 12 o'clock for a point in AppKit coordinates.
    static func angle(of point: CGPoint) -> CGFloat {
        var degrees = atan2(point.x - center.x, point.y - center.y) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    static func sliceCenterAngle(_ index: Int, count: Int) -> CGFloat { CGFloat(index) * step(count) }

    static func childArc(parent: Int, parentCount: Int, childCount: Int) -> (start: CGFloat, width: CGFloat) {
        let width = min(40, 330 / CGFloat(max(childCount, 1)))
        let total = width * CGFloat(childCount)
        return (sliceCenterAngle(parent, count: parentCount) - total / 2, width)
    }

    static func hit(_ point: CGPoint, sliceCount: Int, expanded: Int?, childCount: Int, tabFrames: [WheelMode: CGRect]) -> Hit {
        for (mode, frame) in tabFrames where frame.contains(point) { return .tab(mode) }
        let distance = hypot(point.x - center.x, point.y - center.y)
        if distance <= hubRadius + 2 { return .hub }
        let theta = angle(of: point)
        if distance <= ringOuter + 3 {
            guard sliceCount > 0 else { return .hub }
            let s = step(sliceCount)
            let index = Int(((theta + s / 2).truncatingRemainder(dividingBy: 360)) / s) % sliceCount
            return .slice(index)
        }
        if let expanded, childCount > 0, distance <= childOuter + 26 {
            let arc = childArc(parent: expanded, parentCount: sliceCount, childCount: childCount)
            var delta = (theta - arc.start).truncatingRemainder(dividingBy: 360)
            if delta < 0 { delta += 360 }
            let total = arc.width * CGFloat(childCount)
            if delta < total { return .child(Int(delta / arc.width)) }
        }
        return .none
    }

    /// Point at `degrees` (clockwise from 12) and `radius`, in SwiftUI coordinates.
    static func point(_ degrees: CGFloat, _ radius: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        let c = swiftUICenter
        return CGPoint(x: c.x + radius * sin(radians), y: c.y - radius * cos(radians))
    }
}

/// Header shown in the wheel's hub.
struct SelectionSummary {
    var icon: NSImage
    var title: String
    var subtitle: String

    static func make(for payload: DragPayload) -> SelectionSummary {
        if payload.isPromise {
            let type = payload.promisedTypes.first.flatMap { UTType($0) } ?? .data
            let count = payload.promisedTypes.count
            return SelectionSummary(icon: NSWorkspace.shared.icon(for: type),
                                    title: count == 1 ? (type.localizedDescription ?? "File") : "\(count) files",
                                    subtitle: count == 1 ? "From another app" : "From another app")
        }
        let urls = payload.urls
        if urls.count == 1, let url = urls.first {
            let format = FormatDetector.format(for: url)
            return SelectionSummary(icon: NSWorkspace.shared.icon(forFile: url.path),
                                    title: url.lastPathComponent,
                                    subtitle: format.map { "\($0.name) \($0.category.displayName.lowercased())" } ?? "File")
        }
        let icon = NSWorkspace.shared.icon(forFiles: urls.map(\.path)) ?? NSImage()
        let categories = Set(urls.compactMap { FormatDetector.format(for: $0)?.category })
        let subtitle = categories.count == 1 ? "\(categories.first!.displayName)s" : "Mixed selection"
        return SelectionSummary(icon: icon, title: "\(urls.count) items", subtitle: subtitle)
    }
}

/// Observable state the SwiftUI wheel renders.
@MainActor
final class WheelModel: ObservableObject {
    @Published var mode: WheelMode = .convert
    @Published var nodes: [MenuNode] = []
    @Published var hit: WheelGeometry.Hit = .none
    @Published var expanded: Int?
    @Published var keyboard = false
    @Published var shown = false
    @Published var summary = SelectionSummary(icon: NSImage(), title: "", subtitle: "")
    @Published var keys: [WheelMode: String] = [.convert: "⇧", .tools: "⌘", .actions: "⌃"]
    /// Use solid fills instead of blur materials (for offscreen rendering).
    var solidBackgrounds = false
    /// Tab frames in AppKit coordinates, reported by the SwiftUI layout.
    var tabFrames: [WheelMode: CGRect] = [:]

    var hoveredIndex: Int? {
        if case .slice(let index) = hit { return index }
        if case .child = hit { return expanded }
        return nil
    }

    var hoveredChild: Int? {
        if case .child(let index) = hit { return index }
        return nil
    }

    var children: [MenuNode] {
        guard let expanded, nodes.indices.contains(expanded) else { return [] }
        return nodes[expanded].children
    }

    /// The node a drop or Return would run right now.
    var target: MenuNode? {
        switch hit {
        case .slice(let index): return nodes.indices.contains(index) ? nodes[index] : nil
        case .child(let index): return children.indices.contains(index) ? children[index] : nil
        default: return nil
        }
    }

    var hint: (title: String, detail: String?) {
        if case .hub = hit { return ("Cancel", nil) }
        if case .tab(let mode) = hit { return (mode.title, nil) }
        if let node = target {
            if let reason = node.disabledReason { return (node.detail, reason) }
            if !node.children.isEmpty, let first = node.resolved {
                return (node.detail, "Drop for \(first.title) · more options outside")
            }
            return (node.detail, nil)
        }
        if nodes.isEmpty {
            return (mode == .convert ? "No conversions" : "No tools", "Tap \(keys[.actions] ?? "⌃") for Actions")
        }
        return (summary.title, summary.subtitle)
    }
}
