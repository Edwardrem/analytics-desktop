import SwiftUI
import AppKit
import FacetCore
import FacetDesign

/// Resolved `format["buttons"]` settings for the button slicer.
struct CmpSlButtonConfig {
    var columns: Int
    var rows: Int
    /// "scroll" | "pagination"
    var overflow: String
    var spacing: CGFloat
    var radius: CGFloat
    var minWidth: CGFloat
    var height: CGFloat
    var fill: Color?
    var border: Bool
    var showImages: Bool
    var imageSize: CGFloat

    init(_ env: CmpEnv) {
        let f = env.f
        columns = f.int("buttons", "columns", 0, in: 0...100)
        rows = f.int("buttons", "rows", 0, in: 0...100)
        overflow = f.string("buttons", "overflow", "scroll")
        spacing = f.double("buttons", "spacing", 8)
        radius = f.double("buttons", "radius", 8)
        minWidth = f.double("buttons", "minWidth", 88)
        height = f.double("buttons", "height", 0)
        fill = f.value("buttons", "fill")?.stringValue.map { Color(hex: $0) }
        border = f.bool("buttons", "border", true)
        showImages = f.bool("buttons", "showImages", true)
        imageSize = f.double("buttons", "imageSize", 28)
    }
}

/// Grid of rounded buttons with optional images; scrolls or paginates on overflow. Writes `SlicerState.selected`.
struct CmpSlButtonGrid: View {
    let session: CmpSlSession
    let items: [CmpSlItem]
    let size: CGSize
    @State private var page = 0
    @State private var active = 0
    @State private var keyFocused = false

    var body: some View {
        let env = session.env, cfg = session.cfg
        let b = CmpSlButtonConfig(env)
        let hasImages = b.showImages && items.contains { $0.image != nil }
        let wanted = b.columns > 0 ? b.columns : Int((size.width + b.spacing) / (b.minWidth + b.spacing))
        // Never squeeze buttons below a legible width, whatever the requested column count.
        let fitting = max(1, Int((size.width + b.spacing) / (60 + b.spacing)))
        let cols = max(1, min(max(items.count, 1), wanted, fitting))
        let natural: CGFloat = b.height > 0 ? b.height : (hasImages ? b.imageSize + 34 : max(30, cfg.fontSize + 20))
        let neededRows = Int(ceil(Double(items.count) / Double(cols)))
        let paginate = b.overflow == "pagination"
        // Rows visible at once (fixed by format, or as many as fit).
        let fitRows = max(1, Int((size.height - (paginate ? 22 : 0) + b.spacing) / (natural + b.spacing)))
        let visibleRows = b.rows > 0 ? b.rows : fitRows
        let overflowing = neededRows > visibleRows
        let pagerH: CGFloat = paginate && overflowing ? 22 : 0
        let cappedH: CGFloat = b.rows > 0
            ? max(22, (size.height - pagerH - b.spacing * CGFloat(b.rows - 1)) / CGFloat(b.rows)) : natural
        let pageSize = cols * visibleRows
        let pages = max(1, Int(ceil(Double(items.count) / Double(max(pageSize, 1)))))
        let current = min(page, pages - 1)
        let shown: [CmpSlItem] = paginate && overflowing ? Array(items.dropFirst(current * pageSize).prefix(pageSize)) : items
        let selected = Set(session.state.selected)
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: b.spacing), count: cols), spacing: b.spacing) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                CmpSlButtonCell(item: item, selected: selected.contains(item.value), env: env, cfg: cfg, b: b,
                                height: cappedH, showImage: hasImages, isKeyFocused: keyFocused && active == i) { additive in
                    active = i
                    activate(item, additive: additive)
                }
            }
        }
        VStack(spacing: 4) {
            if paginate {
                grid.frame(maxHeight: .infinity, alignment: .top)
                if overflowing { pager(current: current, pages: pages) }
            } else {
                ScrollView(.vertical) { grid.padding(1) }
            }
        }
        .modifier(CmpSlKeyNav(count: shown.count, columns: cols, enabled: env.isInteractive, active: $active, focused: $keyFocused,
                              activate: { i, additive in
                                  if let item = shown[safe: i] { activate(item, additive: additive || !cfg.commandMulti) }
                              },
                              selectAll: cfg.singleSelect ? nil : { session.update { $0.selected = items.map(\.value) } }))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(VisualTitles.automatic(for: env.spec)) buttons")
    }

    private func pager(current: Int, pages: Int) -> some View {
        let env = session.env
        return HStack(spacing: 8) {
            pagerButton("chevron.left", "Previous page", enabled: current > 0) { page = current - 1; active = 0 }
            HStack(spacing: 4) {
                ForEach(0..<min(pages, 12), id: \.self) { i in
                    Circle().fill(i == current ? session.cfg.selected : env.secondary.opacity(0.35)).frame(width: 5, height: 5)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(current + 1) of \(pages)")
            pagerButton("chevron.right", "Next page", enabled: current < pages - 1) { page = current + 1; active = 0 }
        }
        .frame(height: 18)
    }

    private func pagerButton(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(Design.Motion.quick) { action() } } label: {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .foregroundStyle(session.env.secondary.opacity(enabled ? 1 : 0.35))
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).help(label).accessibilityLabel(label)
    }

    private func activate(_ item: CmpSlItem, additive: Bool) {
        let cfg = session.cfg
        session.update {
            $0.selected = CmpSlLogic.toggle(item.value, in: $0.selected, single: cfg.singleSelect,
                                            additive: cfg.commandMulti ? additive : true, force: cfg.forceSelection)
        }
    }
}

struct CmpSlButtonCell: View {
    let item: CmpSlItem
    let selected: Bool
    let env: CmpEnv
    let cfg: CmpSlConfig
    let b: CmpSlButtonConfig
    let height: CGFloat
    let showImage: Bool
    var isKeyFocused = false
    let action: (Bool) -> Void
    @State private var hovering = false
    @GestureState private var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(b.radius, height / 2), style: .continuous)
        let base = b.fill ?? env.subtleFill
        VStack(spacing: 5) {
            if showImage, height >= b.imageSize + 26 {
                if let src = item.image { CmpSlImageView(source: src, size: b.imageSize) }
                else { Color.clear.frame(width: b.imageSize, height: b.imageSize) }
            }
            Text(item.label)
                .font(env.font(cfg.fontSize, selected ? .semibold : .medium))
                .foregroundStyle(selected ? cfg.onSelected : cfg.text)
                .lineLimit(!showImage && height >= 46 ? 2 : 1).truncationMode(.tail).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(shape.fill(selected ? cfg.selected : base))
        .overlay(shape.fill(env.fg.opacity(pressed ? 0.12 : (hovering && !selected ? 0.05 : 0))))
        .overlay(shape.strokeBorder(selected || !b.border ? Color.clear : env.grid, lineWidth: 1))
        .overlay { if isKeyFocused { shape.strokeBorder(cfg.selected, lineWidth: 2).padding(-3) } }
        .scaleEffect(pressed ? 0.98 : 1)
        .contentShape(shape)
        .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, s, _ in s = true }
            .onEnded { v in
                if abs(v.translation.width) < 8, abs(v.translation.height) < 8 { action(NSEvent.modifierFlags.contains(.command)) }
            })
        .onHover { hovering = $0 }
        .animation(Design.Motion.quick, value: selected)
        .animation(Design.Motion.quick, value: pressed)
        .animation(Design.Motion.quick, value: hovering)
        .help(item.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action(false) }
    }
}
