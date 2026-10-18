import OrbitKit
import SwiftUI

/// An annular sector between two angles (degrees clockwise from 12 o'clock).
struct AnnularSector: Shape {
    var start: CGFloat
    var end: CGFloat
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = max(4, Int(abs(end - start) / 2))
        for i in 0...steps {
            let angle = start + (end - start) * CGFloat(i) / CGFloat(steps)
            let point = WheelGeometry.point(angle, outer)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        for i in stride(from: steps, through: 0, by: -1) {
            path.addLine(to: WheelGeometry.point(start + (end - start) * CGFloat(i) / CGFloat(steps), inner))
        }
        path.closeSubpath()
        return path
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel

    private var g: WheelGeometry.Type { WheelGeometry.self }

    /// Blur materials don't render offscreen (README images), so those use a solid fill.
    private var backdrop: AnyShapeStyle {
        model.solidBackgrounds ? AnyShapeStyle(Color(white: 0.17)) : AnyShapeStyle(.regularMaterial)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            if !model.children.isEmpty, let expanded = model.expanded {
                childRing(parent: expanded)
            }

            ForEach(Array(model.nodes.enumerated()), id: \.element.id) { index, node in
                slice(node, index: index)
            }

            if model.nodes.isEmpty {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: g.ringOuter * 2 - 30, height: g.ringOuter * 2 - 30)
                    .position(g.swiftUICenter)
            }

            hub
            tabs
        }
        .frame(width: g.size.width, height: g.size.height)
        .coordinateSpace(name: "wheel")
        .onPreferenceChange(TabFramesKey.self) { frames in
            // Convert to AppKit's bottom-left origin.
            model.tabFrames = frames.mapValues { CGRect(x: $0.minX, y: g.size.height - $0.maxY, width: $0.width, height: $0.height) }
        }
        .scaleEffect(model.shown ? 1 : 0.82, anchor: UnitPoint(x: g.swiftUICenter.x / g.size.width, y: g.swiftUICenter.y / g.size.height))
        .opacity(model.shown ? 1 : 0)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: model.shown)
        .animation(.easeOut(duration: 0.12), value: model.hit)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: model.expanded)
    }

    // MARK: Slices

    @ViewBuilder
    private func slice(_ node: MenuNode, index: Int) -> some View {
        let count = model.nodes.count
        let step = g.step(count)
        let center = g.sliceCenterAngle(index, count: count)
        let hovered = model.hoveredIndex == index
        let enabled = node.isEnabled
        let gap = count > 1 ? g.gapDegrees : 0

        AnnularSector(start: center - step / 2 + gap, end: center + step / 2 - gap, inner: g.ringInner, outer: g.ringOuter)
            .fill(hovered ? (enabled ? Color.accentColor : Color.secondary.opacity(0.35)) : Color.primary.opacity(0.055))

        let labelRadius = (g.ringInner + g.ringOuter) / 2 + 4
        VStack(spacing: 3) {
            if let symbol = node.symbol {
                Image(systemName: symbol)
                    .font(.system(size: count > 9 ? 14 : 16, weight: .semibold))
            }
            Text(node.title)
                .font(.system(size: labelSize(node.title, count: count), weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !node.children.isEmpty {
                HStack(spacing: 2) {
                    ForEach(0..<min(node.children.count, 5), id: \.self) { _ in
                        Circle().frame(width: 3, height: 3)
                    }
                }
                .opacity(0.55)
            }
        }
        .foregroundColor(hovered && enabled ? .white : .primary)
        .opacity(enabled ? 1 : 0.35)
        .frame(width: max(44, min(78, (2 * .pi * labelRadius) / CGFloat(max(count, 1)) - 6)))
        .position(g.point(center, labelRadius))
        .scaleEffect(hovered ? 1.06 : 1, anchor: .center)
    }

    private func labelSize(_ title: String, count: Int) -> CGFloat {
        let base: CGFloat = count > 10 ? 12 : count > 7 ? 13 : 14
        return title.count > 6 ? base - 1.5 : base
    }

    @ViewBuilder
    private func childRing(parent: Int) -> some View {
        let children = model.children
        let arc = g.childArc(parent: parent, parentCount: model.nodes.count, childCount: children.count)
        let gap: CGFloat = 0.8

        AnnularSector(start: arc.start - 1.5, end: arc.start + arc.width * CGFloat(children.count) + 1.5,
                      inner: g.childInner - 3, outer: g.childOuter + 3)
            .fill(backdrop)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)

        ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
            let start = arc.start + arc.width * CGFloat(index)
            let hovered = model.hoveredChild == index
            AnnularSector(start: start + gap, end: start + arc.width - gap, inner: g.childInner, outer: g.childOuter)
                .fill(hovered ? (child.isEnabled ? Color.accentColor : Color.secondary.opacity(0.35)) : Color.primary.opacity(0.05))
            Text(child.title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundColor(hovered && child.isEnabled ? .white : .primary)
                .opacity(child.isEnabled ? 1 : 0.35)
                .frame(width: max(36, (2 * .pi * (g.childInner + g.childOuter) / 2) * arc.width / 360 - 4))
                .position(g.point(start + arc.width / 2, (g.childInner + g.childOuter) / 2))
        }
    }

    // MARK: Hub

    private var hub: some View {
        let hint = model.hint
        let cancelling = model.hit == .hub
        return ZStack {
            Circle()
                .fill(cancelling ? Color.red.opacity(0.18) : Color.primary.opacity(0.04))
            Circle()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            VStack(spacing: 3) {
                if cancelling {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.red)
                } else if model.target == nil {
                    Image(nsImage: model.summary.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 34, height: 34)
                }
                Text(hint.title)
                    .font(.system(size: model.target == nil ? 10.5 : 11.5, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                if let detail = hint.detail {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundColor(model.target?.isEnabled == false ? .orange : .secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(10)
        }
        .frame(width: g.hubRadius * 2, height: g.hubRadius * 2)
        .position(g.swiftUICenter)
    }

    // MARK: Mode tabs

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(WheelMode.allCases) { mode in
                let active = model.mode == mode
                let hovered = model.hit == .tab(mode)
                HStack(spacing: 5) {
                    Text(model.keys[mode] ?? "")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(active ? Color.white.opacity(0.25) : Color.primary.opacity(0.08)))
                    Text(mode.title)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(active ? .white : .primary)
                .padding(.horizontal, 10)
                .frame(height: g.tabsHeight)
                .background(Capsule().fill(active ? Color.accentColor : hovered ? Color.primary.opacity(0.12) : Color.clear))
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: TabFramesKey.self, value: [mode: proxy.frame(in: .named("wheel"))])
                })
            }
        }
        .padding(3)
        .background(Capsule().fill(backdrop).shadow(color: .black.opacity(0.18), radius: 8, y: 2))
        .frame(width: g.size.width)
        .position(x: g.size.width / 2, y: g.tabsTop + g.tabsHeight / 2 + 3)
    }
}

/// Collects each mode tab's frame so the AppKit layer can hit-test it.
struct TabFramesKey: PreferenceKey {
    static var defaultValue: [WheelMode: CGRect] = [:]
    static func reduce(value: inout [WheelMode: CGRect], nextValue: () -> [WheelMode: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
