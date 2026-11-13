import SwiftUI
import AppKit
import FacetCore
import FacetDesign

/// One interactive mark: its hit shape, the data point it represents and what to say about it.
/// The tooltip is built lazily (only for the mark under the pointer), so charts with thousands of
/// marks stay cheap to lay out.
public struct ChartHit: Identifiable {
    public var id: Int
    /// Hit shape in the interaction layer's coordinate space.
    public var path: Path
    /// Where the tooltip attaches and the keyboard focus ring is centred.
    public var anchor: CGPoint
    public var selection: DataPointSelection?
    let makeTooltip: () -> TooltipContent
    let copyOverride: String
    let labelOverride: String

    public var tooltip: TooltipContent { makeTooltip() }
    /// Text placed on the pasteboard by "Copy value".
    public var copyText: String {
        if !copyOverride.isEmpty { return copyOverride }
        let t = makeTooltip()
        return t.rows.first(where: \.isEmphasized)?.value ?? t.rows.first?.value ?? t.title
    }
    public var accessibilityLabel: String {
        if !labelOverride.isEmpty { return labelOverride }
        let t = makeTooltip()
        return ([t.title] + t.rows.map { "\($0.label) \($0.value)" }).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    public init(id: Int, path: Path, anchor: CGPoint? = nil, selection: DataPointSelection?,
                tooltip: @autoclosure @escaping () -> TooltipContent, copyText: String = "", accessibilityLabel: String = "") {
        self.id = id; self.path = path
        if let anchor { self.anchor = anchor } else { let b = path.boundingRect; self.anchor = CGPoint(x: b.midX, y: b.midY) }
        self.selection = selection; self.makeTooltip = tooltip
        self.copyOverride = copyText; self.labelOverride = accessibilityLabel
    }

    public init(id: Int, rect: CGRect, anchor: CGPoint? = nil, selection: DataPointSelection?,
                tooltip: @autoclosure @escaping () -> TooltipContent, copyText: String = "", accessibilityLabel: String = "") {
        self.init(id: id, path: Path(rect), anchor: anchor, selection: selection, tooltip: tooltip(), copyText: copyText,
                  accessibilityLabel: accessibilityLabel)
    }
}

/// Decides which marks stay emphasised for the visual's current selection. A mark is emphasised when
/// nothing is selected, or when some selected point's field/value pairs are all present in the mark's
/// own selection (so selecting a legend value emphasises every mark of that series).
public struct SelectionMatcher {
    private let selected: [Set<String>]
    public init(_ selection: [DataPointSelection]) {
        selected = selection.map { SelectionMatcher.pairs($0) }.filter { !$0.isEmpty }
    }
    public var isActive: Bool { !selected.isEmpty }
    static func pairs(_ p: DataPointSelection) -> Set<String> {
        Set(zip(p.fields, p.values).map { "\($0.key)=\($1.asString)" })
    }
    public func isSelected(_ p: DataPointSelection) -> Bool {
        guard isActive else { return false }
        let mine = SelectionMatcher.pairs(p)
        return selected.contains { $0.isSubset(of: mine) }
    }
    /// 1 for emphasised marks, 0.3 for the rest.
    public func emphasis(_ p: DataPointSelection) -> Double { !isActive || isSelected(p) ? 1 : 0.3 }
}

/// Reports scroll-wheel / trackpad scrolling while the pointer is over the view (used to pan zoomed charts).
struct ScrollWheelModifier: ViewModifier {
    let isEnabled: Bool
    let action: (_ dx: CGFloat, _ dy: CGFloat) -> Void
    @State private var hovering = false
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .onChange(of: hovering && isEnabled, initial: true) { _, active in
                if active, monitor == nil {
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                        action(event.scrollingDeltaX, event.scrollingDeltaY)
                        return nil
                    }
                } else if !active, let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            }
            .onDisappear { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
    }
}

public extension View {
    /// Calls `action` with scroll deltas while the pointer is over this view; the events are consumed.
    func onScrollWheel(isEnabled: Bool = true, _ action: @escaping (_ dx: CGFloat, _ dy: CGFloat) -> Void) -> some View {
        modifier(ScrollWheelModifier(isEnabled: isEnabled, action: action))
    }
}

/// Transparent layer that gives any chart its standard behaviour from a list of `ChartHit`s:
/// hover tooltip, click / ⌘-click selection, click-on-empty to clear, rectangle (lasso) select,
/// double-click drill down, the data-point context menu, and keyboard navigation
/// (← → to move between marks, Return to select, Esc to clear).
public struct ChartInteractionLayer: View {
    let hits: [ChartHit]
    let spec: VisualSpec
    let context: VisualContext
    /// Enables drag-to-select.
    var allowsLasso = false
    /// Extra distance within which the nearest mark anchor is picked when no shape contains the pointer.
    var snapRadius: CGFloat = 0
    /// How the hovered mark is outlined.
    var highlight: HoverHighlight = .outline
    /// Adds hidden accessibility children for each hit (use for Canvas-drawn charts; Swift Charts marks
    /// already expose themselves).
    var exposesAccessibility = false
    /// Called when the hovered mark changes (e.g. to draw a crosshair).
    var onHover: ((ChartHit?) -> Void)?

    public enum HoverHighlight { case outline, none }

    @State private var hover: Int?
    @State private var pointer: CGPoint = .zero
    @State private var overCard = false
    @State private var cardSize: CGSize = CGSize(width: 140, height: 50)
    @State private var dragRect: CGRect?
    @State private var focusIndex: Int?
    @State private var clearTask: DispatchWorkItem?
    @FocusState private var focused: Bool

    public init(hits: [ChartHit], spec: VisualSpec, context: VisualContext, allowsLasso: Bool = false, snapRadius: CGFloat = 0,
                highlight: HoverHighlight = .outline, exposesAccessibility: Bool = false, onHover: ((ChartHit?) -> Void)? = nil) {
        self.hits = hits; self.spec = spec; self.context = context; self.allowsLasso = allowsLasso
        self.snapRadius = snapRadius; self.highlight = highlight; self.exposesAccessibility = exposesAccessibility; self.onHover = onHover
    }

    public var body: some View {
        if context.isInteractive {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    surface(geo.size)
                    decorations.allowsHitTesting(false)
                    if let hit = activeHit, dragRect == nil {
                        TooltipCard(content: hit.tooltip, theme: context.theme, actions: actions(for: hit))
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                            .onHover { inside in overCard = inside; if !inside { scheduleClear() } }
                            .offset(tooltipOffset(in: geo.size, hit: hit))
                            .transition(.opacity)
                            .zIndex(10)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        } else if exposesAccessibility {
            Color.clear.accessibilityChildren { accessibilityChildren }
        }
    }

    // MARK: Surface

    private func surface(_ size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    pointer = p
                    clearTask?.cancel()
                    let h = hitIndex(at: p)
                    if h != hover { setHover(h) }
                case .ended:
                    scheduleClear()
                }
            }
            .gesture(SpatialTapGesture().onEnded { tap(at: $0.location) })
            .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { v in
                guard allowsLasso else { return }
                dragRect = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                  width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
            }.onEnded { _ in
                guard allowsLasso, let r = dragRect else { return }
                dragRect = nil
                var seen = Set<String>()
                let points = hits.filter { $0.path.boundingRect.intersects(r) }.compactMap(\.selection)
                    .filter { !$0.fields.isEmpty && seen.insert($0.key).inserted }
                context.onSelect(points, NSEvent.modifierFlags.contains(.command))
            })
            .contextMenu { menu }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.rightArrow) { moveFocus(1) }
            .onKeyPress(.downArrow) { moveFocus(1) }
            .onKeyPress(.leftArrow) { moveFocus(-1) }
            .onKeyPress(.upArrow) { moveFocus(-1) }
            .onKeyPress(.return) { activateFocus() }
            .onKeyPress(.space) { activateFocus() }
            .onKeyPress(.escape) { focusIndex = nil; context.onSelect([], false); return .handled }
            .onChange(of: focused) { _, f in if !f { focusIndex = nil } }
            .accessibilityChildren { if exposesAccessibility { accessibilityChildren } }
    }

    @ViewBuilder private var accessibilityChildren: some View {
        ForEach(hits.prefix(400)) { h in
            Rectangle().accessibilityLabel(h.accessibilityLabel).accessibilityAddTraits(.isButton)
                .accessibilityAction { if let s = h.selection { context.onSelect([s], false) } }
        }
    }

    @ViewBuilder private var decorations: some View {
        if let hit = activeHit, highlight == .outline || focusIndex != nil {
            hit.path.stroke(context.theme.foregroundColor.opacity(focusIndex != nil ? 0.9 : 0.55),
                            lineWidth: focusIndex != nil ? 2 : 1)
        }
        if let r = dragRect {
            Rectangle().fill(context.theme.accentColor.opacity(0.10))
                .overlay(Rectangle().strokeBorder(context.theme.accentColor.opacity(0.7), lineWidth: 1))
                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
        }
    }

    // MARK: State helpers

    private var activeHit: ChartHit? {
        if let f = focusIndex, hits.indices.contains(f) { return hits[f] }
        if let h = hover, hits.indices.contains(h) { return hits[h] }
        return nil
    }

    private func hitIndex(at p: CGPoint) -> Int? {
        for i in hits.indices.reversed() where hits[i].path.contains(p) { return i }
        guard snapRadius > 0 else { return nil }
        var best: Int?, bestD = snapRadius * snapRadius
        for (i, h) in hits.enumerated() {
            let d = (h.anchor.x - p.x) * (h.anchor.x - p.x) + (h.anchor.y - p.y) * (h.anchor.y - p.y)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    private func setHover(_ h: Int?) {
        withAnimation(Design.Motion.quick) { hover = h }
        onHover?(h.flatMap { hits[safe: $0] })
    }

    private func scheduleClear() {
        clearTask?.cancel()
        let task = DispatchWorkItem { if !overCard { setHover(nil) } }
        clearTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }

    private func tap(at p: CGPoint) {
        focused = true
        let additive = NSEvent.modifierFlags.contains(.command)
        guard let i = hitIndex(at: p), let sel = hits[i].selection, !sel.fields.isEmpty else {
            if !additive { context.onSelect([], false) }
            return
        }
        if (NSApp?.currentEvent?.clickCount ?? 1) >= 2 { context.onDrill(.down(sel)) }
        else { context.onSelect([sel], additive) }
    }

    private func moveFocus(_ delta: Int) -> KeyPress.Result {
        guard !hits.isEmpty else { return .ignored }
        let next = ((focusIndex ?? (delta > 0 ? -1 : 0)) + delta + hits.count) % hits.count
        focusIndex = next
        pointer = hits[next].anchor
        return .handled
    }

    private func activateFocus() -> KeyPress.Result {
        guard let f = focusIndex, let sel = hits[safe: f]?.selection else { return .ignored }
        context.onSelect([sel], NSEvent.modifierFlags.contains(.command))
        return .handled
    }

    private func tooltipOffset(in size: CGSize, hit: ChartHit) -> CGSize {
        let p = focusIndex != nil ? hit.anchor : pointer
        var x = p.x + 14, y = p.y + 14
        if x + cardSize.width > size.width { x = p.x - 14 - cardSize.width }
        if y + cardSize.height > size.height { y = p.y - 14 - cardSize.height }
        x = max(0, min(x, size.width - cardSize.width))
        y = max(0, min(y, size.height - cardSize.height))
        return CGSize(width: x, height: y)
    }

    // MARK: Actions

    private func actions(for hit: ChartHit) -> [TooltipAction] {
        guard let sel = hit.selection, !sel.fields.isEmpty else { return [] }
        return [
            TooltipAction(title: "Drill down", systemImage: "arrow.down.to.line") { context.onDrill(.down(sel)) },
            TooltipAction(title: "Drill through", systemImage: "arrow.up.right.square") { context.onDrill(.drillthrough(sel, pageID: nil)) },
        ]
    }

    @ViewBuilder private var menu: some View {
        let hit = activeHit
        let sel = hit?.selection.flatMap { $0.fields.isEmpty ? nil : $0 }
        if let sel {
            Button("Drill down") { context.onDrill(.down(sel)) }
        }
        Button("Drill up") { context.onDrill(.up) }
        Button("Expand to next level") { context.onDrill(.expandAll) }
        if let sel {
            Button("Drill through") { context.onDrill(.drillthrough(sel, pageID: nil)) }
        }
        Divider()
        Button("Show as a table") { context.onDrill(.showAsTable) }
        if let hit {
            Button("Copy value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hit.copyText, forType: .string)
            }
        }
    }
}

/// Two-thumb range slider used as the zoom slider under cartesian charts. `range` is a fraction 0…1.
public struct ZoomSlider: View {
    @Binding var range: ClosedRange<Double>
    let theme: ThemeSpec
    var minimumSpan: Double = 0.02
    var maximumSpan: Double = 1
    public init(range: Binding<ClosedRange<Double>>, theme: ThemeSpec, minimumSpan: Double = 0.02, maximumSpan: Double = 1) {
        self._range = range; self.theme = theme; self.minimumSpan = minimumSpan; self.maximumSpan = max(minimumSpan, maximumSpan)
    }
    @State private var dragStart: ClosedRange<Double>?

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x0 = range.lowerBound * w, x1 = range.upperBound * w
            ZStack(alignment: .leading) {
                Capsule().fill(theme.gridlineColor.opacity(0.7)).frame(height: 4)
                Capsule().fill(theme.secondaryColor.opacity(0.55)).frame(width: max(8, x1 - x0), height: 4).offset(x: x0)
                    .contentShape(Rectangle().inset(by: -6))
                    .gesture(drag(w) { s, d in
                        let span = s.upperBound - s.lowerBound
                        let lo = max(0, min(1 - span, s.lowerBound + d))
                        return lo...(lo + span)
                    })
                thumb.offset(x: x0 - 5).gesture(drag(w) { s, d in
                    min(max(0, s.upperBound - maximumSpan, s.lowerBound + d), s.upperBound - minimumSpan)...s.upperBound
                })
                thumb.offset(x: x1 - 5).gesture(drag(w) { s, d in
                    s.lowerBound...max(min(1, s.lowerBound + maximumSpan, s.upperBound + d), s.lowerBound + minimumSpan)
                })
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel("Zoom")
        .accessibilityValue("\(Int(range.lowerBound * 100)) to \(Int(range.upperBound * 100)) percent")
    }

    private var thumb: some View {
        Circle().fill(theme.cardColor).frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(theme.secondaryColor.opacity(0.8), lineWidth: 1))
            .contentShape(Circle().inset(by: -5))
    }

    private func drag(_ width: CGFloat, _ update: @escaping (ClosedRange<Double>, Double) -> ClosedRange<Double>) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let start = dragStart ?? range
                if dragStart == nil { dragStart = range }
                range = update(start, Double(v.translation.width / max(width, 1)))
            }
            .onEnded { _ in dragStart = nil }
    }
}

/// Renders visuals off-screen for thumbnails, export and snapshot checks.
public enum ChartRendering {
    /// PNG of the complete visual (container chrome, title and body) at `size` points.
    /// Hover-only elements (tooltips) are not part of the image.
    @MainActor
    public static func renderPNG(spec: VisualSpec, data: VisualData, context: VisualContext, size: CGSize, scale: CGFloat = 2) -> Data? {
        var ctx = context
        ctx.isInteractive = false
        let view = VisualView(spec: spec, data: data, context: ctx)
            .frame(width: size.width, height: size.height)
            .background(context.theme.backgroundColor)
            .environment(\.colorScheme, context.theme.isDark ? .dark : .light)
        return renderPNG(view, scale: scale)
    }

    /// PNG of any SwiftUI view at its ideal size.
    @MainActor
    public static func renderPNG<V: View>(_ view: V, scale: CGFloat = 2) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
