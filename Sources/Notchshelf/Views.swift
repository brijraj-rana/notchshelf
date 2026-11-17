import NotchshelfCore
import SwiftUI

// MARK: Geometry

enum Mode: Equatable {
    case hidden     // empty shelf, nothing being dragged: no trace
    case ear        // holding files: a small count beside the notch
    case hint       // a file is being dragged somewhere on screen: a lip drops out as the target
    case open       // the shelf itself
}

struct NotchGeometry: Equatable {
    var notchWidth: CGFloat = 185
    var notchHeight: CGFloat = 32          // 0 on a screen without a notch
    var earWidth: CGFloat = 44
    var lipHeight: CGFloat = 26
    var openWidth: CGFloat = 440
    var openHeight: CGFloat = 138
    var margin: CGFloat = 40               // room for the shadow

    var hasNotch: Bool { notchHeight > 0 }

    var windowSize: CGSize {
        CGSize(width: openWidth + margin * 2, height: notchHeight + openHeight + margin)
    }

    struct Dims: Equatable {
        var ear: CGFloat
        var width: CGFloat
        var height: CGFloat
        var radius: CGFloat
    }

    func dims(_ mode: Mode, hasItems: Bool) -> Dims {
        switch mode {
        case .hidden:
            return Dims(ear: 0, width: notchWidth, height: 0, radius: 10)
        case .ear:
            // Without a notch there is no band to sit in, so the count hangs below the menu bar instead.
            return hasNotch
                ? Dims(ear: earWidth, width: notchWidth, height: 0, radius: 10)
                : Dims(ear: 0, width: notchWidth, height: lipHeight, radius: 10)
        case .hint:
            return Dims(ear: hasNotch && hasItems ? earWidth : 0, width: notchWidth, height: lipHeight, radius: 10)
        case .open:
            return Dims(ear: 0, width: openWidth, height: openHeight, radius: 18)
        }
    }
}

final class PanelState: ObservableObject {
    @Published var mode: Mode = .hidden
    @Published var geo = NotchGeometry()
    @Published var targeted = false        // a drag is hovering over the shelf right now
}

/// What the views can ask the controller to do.
@MainActor
final class ShelfActions {
    var remove: (UUID) -> Void = { _ in }
    var clear: () -> Void = {}
    var open: (UUID) -> Void = { _ in }
    var beginDrag: ([UUID], NSView, NSEvent) -> Void = { _, _, _ in }
}

private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while rendering README images, where AppKit-backed views cannot be drawn.
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

// MARK: Shape

/// The notch column, an optional ear to its right inside the menu bar band, and a body below. One path for every mode.
struct ShelfShape: Shape {
    var ear: CGFloat
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var notchWidth: CGFloat
    var notchHeight: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(ear, width), AnimatablePair(height, radius)) }
        set {
            ear = newValue.first.first
            width = newValue.first.second
            height = newValue.second.first
            radius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let nh = notchHeight
        let h = max(0, height)
        let w = max(notchWidth, width)
        let left = cx - notchWidth / 2
        let right = cx + notchWidth / 2 + max(0, ear)
        let bodyLeft = cx - w / 2
        let bodyRight = cx + w / 2
        let r = max(0, radius)

        var corners: [(CGPoint, CGFloat)]
        if nh <= 0 {
            guard h > 0.5 else { return Path() }
            corners = [
                (CGPoint(x: bodyLeft, y: 0), 0), (CGPoint(x: bodyRight, y: 0), 0),
                (CGPoint(x: bodyRight, y: h), r), (CGPoint(x: bodyLeft, y: h), r),
            ]
        } else if h <= 0.5 {
            corners = [
                (CGPoint(x: left, y: 0), 0), (CGPoint(x: right, y: 0), 0),
                (CGPoint(x: right, y: nh), 10), (CGPoint(x: left, y: nh), 10),
            ]
        } else {
            corners = [
                (CGPoint(x: left, y: 0), 0), (CGPoint(x: right, y: 0), 0),
                (CGPoint(x: right, y: nh), 10), (CGPoint(x: bodyRight, y: nh), 10),
                (CGPoint(x: bodyRight, y: nh + h), r), (CGPoint(x: bodyLeft, y: nh + h), r),
                (CGPoint(x: bodyLeft, y: nh), 10), (CGPoint(x: left, y: nh), 10),
            ]
        }
        return Self.roundedPolygon(corners)
    }

    /// A closed polygon with a radius per corner. Each radius shrinks to fit its shortest neighbouring edge,
    /// so the outline stays valid while edges grow from nothing mid-animation.
    static func roundedPolygon(_ input: [(CGPoint, CGFloat)]) -> Path {
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

        var points: [(CGPoint, CGFloat)] = []
        for point in input {
            if let last = points.last, distance(last.0, point.0) < 0.5 { continue }
            points.append(point)
        }
        if points.count > 1, distance(points[0].0, points[points.count - 1].0) < 0.5 { points.removeLast() }
        guard points.count >= 3 else { return Path() }

        let n = points.count
        var path = Path()
        let first = points[0].0, last = points[n - 1].0
        path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
        for i in 0..<n {
            let current = points[i].0
            let previous = points[(i + n - 1) % n].0
            let next = points[(i + 1) % n].0
            let radius = min(points[i].1, distance(previous, current) / 2, distance(current, next) / 2)
            if radius < 0.5 {
                path.addLine(to: current)
            } else {
                path.addArc(tangent1End: current, tangent2End: next, radius: radius)
            }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: Small states

/// The count beside the notch while the shelf is holding something.
struct EarView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text("\(count)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText())
        }
        .padding(.trailing, 4)
    }
}

/// The strip under the notch: a drop target during a drag, or the count on a screen without a notch.
struct LipView: View {
    let dragging: Bool
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: dragging ? "arrow.down" : "tray.full.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
            Text(dragging ? "Drop to shelve" : "\(count) on the shelf")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.bottom, 3)
    }
}

// MARK: Shelf

struct TileView: View {
    let item: ShelfItem
    let actions: ShelfActions
    @State private var image: NSImage?
    @State private var hovering = false
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: image ?? Thumbnailer.cached(item.url) ?? Thumbnailer.icon(for: item.url))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .frame(width: 62, height: 54)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(width: 80)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(hovering ? 0.1 : 0)))
        .overlay {
            if !isSnapshot {
                Interaction(ids: [item.id], actions: actions, onHover: { hovering = $0 }, onOpen: { actions.open(item.id) })
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    actions.remove(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color(white: 0.32)))
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityLabel("Remove \(item.name) from the shelf")
            }
        }
        .task(id: item.url) {
            if let thumbnail = await Thumbnailer.thumbnail(for: item.url) { image = thumbnail }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
    }
}

struct ShelfView: View {
    let items: [ShelfItem]
    let targeted: Bool
    let actions: ShelfActions
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if items.isEmpty {
                placeholder
            } else if isSnapshot {
                tiles.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) { tiles }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("SHELF")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.45))
            if !items.isEmpty {
                Text("\(items.count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .contentTransition(.numericText())
            }
            Spacer()
            if items.count > 1 {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack.fill").font(.system(size: 8.5, weight: .semibold))
                    Text("Drag all")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(.white.opacity(0.1)))
                .overlay {
                    if !isSnapshot { Interaction(ids: items.map(\.id), actions: actions) }
                }
                .accessibilityLabel("Drag all \(items.count) files")
            }
            if !items.isEmpty {
                Button("Clear") { actions.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 4)
                    .frame(height: 20)
                    .contentShape(Rectangle())
            }
        }
        .frame(height: 20)
    }

    private var tiles: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                TileView(item: item, actions: actions)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(.white.opacity(targeted ? 0.6 : 0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(targeted ? 0.08 : 0)))
            .overlay {
                Text(targeted ? "Let go to park it here" : "Drag files here to park them")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(targeted ? 0.9 : 0.5))
            }
    }
}

// MARK: Root

struct RootView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: ShelfStore
    let actions: ShelfActions
    var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let g = state.geo
        let count = store.items.count
        let d = g.dims(state.mode, hasItems: count > 0)
        let shape = ShelfShape(ear: d.ear, width: d.width, height: d.height, radius: d.radius,
                               notchWidth: g.notchWidth, notchHeight: g.notchHeight)
        let open = state.mode == .open
        let lip = state.mode == .hint || (state.mode == .ear && !g.hasNotch)
        let spring: Animation = reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.82)

        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .shadow(color: .black.opacity(open ? 0.4 : 0), radius: 14, y: 6)

            ZStack(alignment: .top) {
                if d.ear > 0 {
                    EarView(count: count)
                        .frame(width: g.earWidth, height: g.notchHeight)
                        .offset(x: (g.notchWidth + g.earWidth) / 2)
                        .transition(.opacity)
                }
                if lip {
                    LipView(dragging: state.mode == .hint, count: count)
                        .frame(width: g.notchWidth, height: g.lipHeight)
                        .padding(.top, g.notchHeight)
                        .transition(.opacity)
                }
                // Always mounted, so a tile being dragged out keeps its view while the panel closes behind it.
                ShelfView(items: store.items, targeted: state.targeted, actions: actions)
                    .frame(width: g.openWidth, height: g.openHeight)
                    .padding(.top, g.notchHeight)
                    .opacity(open ? 1 : 0)
                    .allowsHitTesting(open)

                if state.targeted && open && count > 0 {
                    // Half of this stroke falls outside the mask, leaving a 1.5 point inner edge.
                    shape.stroke(.white.opacity(0.45), lineWidth: 3)
                }
            }
            .frame(width: g.windowSize.width, height: g.windowSize.height, alignment: .top)
            .mask(shape)
        }
        .frame(width: g.windowSize.width, height: g.windowSize.height, alignment: .top)
        .animation(spring, value: state.mode)
        .animation(spring, value: store.items.map(\.id))
        .animation(.easeOut(duration: 0.12), value: state.targeted)
        .ignoresSafeArea()
    }
}
