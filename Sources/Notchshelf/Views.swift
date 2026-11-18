import NotchshelfCore
import SwiftUI

// MARK: Geometry

enum Mode: Equatable {
    case hidden     // empty shelf, nothing being dragged: no trace
    case ear        // holding files: a small count beside the notch
    case hint       // a file is being dragged somewhere on screen: a lip drops out as the target
    case open       // the shelf itself
    case recording  // waiting for a new keyboard shortcut
}

struct NotchGeometry: Equatable {
    var notchWidth: CGFloat = 185
    var notchHeight: CGFloat = 32          // 0 on a screen without a notch
    var earWidth: CGFloat = 44
    var lipHeight: CGFloat = 26
    var openWidth: CGFloat = 440
    var openHeight: CGFloat = 138
    var recordWidth: CGFloat = 280
    var recordHeight: CGFloat = 92
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
        case .recording:
            return Dims(ear: 0, width: recordWidth, height: recordHeight, radius: 18)
        }
    }
}

final class PanelState: ObservableObject {
    @Published var mode: Mode = .hidden
    @Published var geo = NotchGeometry()
    @Published var targeted = false        // a drag is hovering over the shelf right now
    @Published var selection: UUID?        // the tile the keyboard acts on
    @Published var notice: String?         // a word in the header after an action with nothing else to show for it
    @Published var recorder = RecorderState()
    /// Set while a change comes from a key press, which should land at once instead of springing.
    var instant = false
}

/// What the shortcut recorder is showing.
struct RecorderState: Equatable {
    enum Phase: Equatable {
        case waiting
        case rejected(String)
        case saved
    }

    var keys: [String] = []                // the shortcut in use, or the one just recorded
    var held: [String] = []                // modifiers being held down right now
    var phase: Phase = .waiting
}

/// What the views can ask the controller to do.
@MainActor
final class ShelfActions {
    var remove: (UUID) -> Void = { _ in }
    var clear: () -> Void = {}
    var open: (UUID) -> Void = { _ in }
    var hover: (UUID, Bool) -> Void = { _, _ in }
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

enum Motion {
    /// For small things that follow the hand: the selection moving, a tile being pressed.
    static let quick: Animation = .timingCurve(0.22, 1, 0.36, 1, duration: 0.15)
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
    var selected = false
    let actions: ShelfActions
    @State private var image: NSImage?
    @State private var hovering = false
    @State private var pressed = false
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: image ?? Thumbnailer.cached(item.url) ?? Thumbnailer.icon(for: item.url))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .frame(width: 62, height: 54)
                .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
                .animation(Motion.quick, value: pressed)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(width: 80)
        .id(item.id)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(hovering ? 0.1 : 0)))
        .overlay {
            if !isSnapshot {
                Interaction(ids: [item.id], actions: actions,
                            onHover: { hovering = $0; actions.hover(item.id, $0) },
                            onPress: { pressed = $0 },
                            onOpen: { actions.open(item.id) })
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
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ShelfView: View {
    let items: [ShelfItem]
    let targeted: Bool
    var selection: UUID?
    var notice: String?
    let actions: ShelfActions
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tileWidth: CGFloat = 80
    private let tileSpacing: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if items.isEmpty {
                placeholder
            } else if isSnapshot {
                tiles.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) { tiles }
                        .onChange(of: selection) { _, id in
                            // No animation: the selection only ever changes here on a key press.
                            if let id { proxy.scrollTo(id) }
                        }
                }
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
            if let notice {
                Text(notice)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.leading, 4)
                    .transition(.identity)
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
        HStack(spacing: tileSpacing) {
            ForEach(items) { item in
                TileView(item: item, selected: item.id == selection, actions: actions)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .background(alignment: .leading) {
            // One highlight that slides between tiles, instead of one per tile fading in and out.
            if let index = items.firstIndex(where: { $0.id == selection }) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    .frame(width: tileWidth)
                    .offset(x: CGFloat(index) * (tileWidth + tileSpacing))
                    .animation(reduceMotion ? nil : Motion.quick, value: index)
                    .transition(.identity)
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

// MARK: Shortcut recorder

struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 7)
            .frame(minWidth: 26)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.1)))
    }
}

/// Shown in place of the shelf while the app waits for a new shortcut.
struct RecorderView: View {
    let recorder: RecorderState

    private var message: String {
        switch recorder.phase {
        case .waiting: return "Press the new shortcut"
        case .rejected(let reason): return reason
        case .saved: return "Shortcut set"
        }
    }

    var body: some View {
        let saved = recorder.phase == .saved
        let holding = !recorder.held.isEmpty && !saved

        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("SHORTCUT")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                if !saved {
                    Text("Esc to cancel")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(height: 20)

            HStack(spacing: 4) {
                ForEach(Array((holding ? recorder.held : recorder.keys).enumerated()), id: \.offset) { _, key in
                    Keycap(label: key)
                }
                if holding || recorder.keys.isEmpty {
                    // The key still to come.
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(width: 26, height: 26)
                }
            }
            // The shortcut in use sits back until it is replaced.
            .opacity(saved || holding ? 1 : 0.45)

            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(recorder.phase == .waiting ? 0.5 : 0.9))
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(saved ? "Shortcut set to \(recorder.keys.joined(separator: " "))" : "\(message). Escape cancels.")
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
        let recording = state.mode == .recording
        let lip = state.mode == .hint || (state.mode == .ear && !g.hasNotch)
        let spring: Animation? = state.instant ? nil
            : (reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.82))

        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .shadow(color: .black.opacity(open || recording ? 0.4 : 0), radius: 14, y: 6)

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
                ShelfView(items: store.items, targeted: state.targeted, selection: state.selection, notice: state.notice, actions: actions)
                    .frame(width: g.openWidth, height: g.openHeight)
                    .padding(.top, g.notchHeight)
                    .opacity(open ? 1 : 0)
                    .allowsHitTesting(open)

                if recording {
                    RecorderView(recorder: state.recorder)
                        .frame(width: g.recordWidth, height: g.recordHeight)
                        .padding(.top, g.notchHeight)
                        .transition(.opacity)
                }

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
