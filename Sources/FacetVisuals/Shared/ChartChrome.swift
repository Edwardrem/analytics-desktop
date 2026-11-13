import SwiftUI
import FacetCore
import FacetDesign

/// Theme-derived drawing constants every chart shares, so type, hairlines and motion stay consistent.
public struct ChartStyle {
    public let theme: ThemeSpec
    public let format: ResolvedFormat

    public init(spec: VisualSpec, theme: ThemeSpec) {
        self.theme = theme
        self.format = ResolvedFormat(spec: spec, theme: theme)
    }

    public var labelSize: CGFloat { CGFloat(theme.label.size) }
    public var foreground: Color { theme.foregroundColor }
    public var secondary: Color { theme.secondaryColor }
    public var card: Color { theme.cardColor }
    /// Hairline gridline colour; full strength in high-contrast themes.
    public var grid: Color { theme.isHighContrast ? theme.gridlineColor.opacity(0.6) : theme.gridlineColor }
    public var gridWidth: CGFloat { theme.isHighContrast ? 1 : 0.5 }
    /// Slightly stronger hairline for the zero baseline.
    public var baseline: Color { theme.isHighContrast ? theme.foregroundColor : theme.secondaryColor.opacity(0.45) }
    /// Knock-out colour for accessibility patterns drawn over fills.
    public var patternInk: Color { theme.cardColor.opacity(theme.isHighContrast ? 0.9 : 0.6) }
    public var usesPatterns: Bool { format.bool("accessibility", "patterns", theme.isHighContrast) }

    public func font(_ size: CGFloat? = nil, weight: Font.Weight = .regular) -> Font {
        let s = size ?? labelSize
        return theme.label.fontFamily.isEmpty ? .system(size: s, weight: weight) : .custom(theme.label.fontFamily, size: s).weight(weight)
    }
    /// Label font size after applying a `<card>.size` override.
    public func size(_ card: String, _ fallback: CGFloat? = nil) -> CGFloat {
        CGFloat(format.double(card, "size", Double(fallback ?? labelSize)))
    }
}

/// What a chart of a given pixel size has room for. Charts shed secondary elements as they shrink.
public struct ChartSizeClass {
    public let size: CGSize
    public init(_ size: CGSize) { self.size = size }
    public var showLegend: Bool { size.width >= 220 && size.height >= 150 }
    public var showAxisLabels: Bool { size.width >= 140 && size.height >= 84 }
    public var showAxisTitles: Bool { size.width >= 320 && size.height >= 230 }
    public var showDataLabels: Bool { size.width >= 200 && size.height >= 130 }
    /// Desired number of value-axis ticks along a dimension of `length` points.
    public static func tickCount(_ length: CGFloat) -> Int { max(2, min(6, Int(length / 48))) }
}

/// Quiet placeholder shown when a chart's required wells are empty.
public struct ChartPlaceholder: View {
    let systemImage: String
    let title: String
    let message: String
    let theme: ThemeSpec
    public init(systemImage: String = "chart.bar", title: String, message: String, theme: ThemeSpec) {
        self.systemImage = systemImage; self.title = title; self.message = message; self.theme = theme
    }
    public var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 200 || geo.size.height < 120
            VStack(spacing: compact ? 4 : Design.Space.s) {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 16 : 26, weight: .light))
                    .foregroundStyle(theme.secondaryColor.opacity(0.55))
                if geo.size.height >= 70 {
                    Text(compact ? message : title).font(.system(size: compact ? 10 : 13, weight: .medium))
                        .foregroundStyle(theme.secondaryColor)
                        .multilineTextAlignment(.center).lineLimit(2)
                }
                if !compact {
                    Text(message).font(.system(size: 11)).foregroundStyle(theme.secondaryColor.opacity(0.75))
                        .multilineTextAlignment(.center).frame(maxWidth: 260)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(message)")
    }
}

// MARK: - Tooltip

/// Contents of a tooltip: a header and rows of swatch / label / value.
public struct TooltipContent {
    public struct Row: Identifiable {
        public let id = UUID()
        public var color: Color?
        public var label: String
        public var value: String
        public var isEmphasized: Bool
        public init(color: Color? = nil, label: String, value: String, isEmphasized: Bool = false) {
            self.color = color; self.label = label; self.value = value; self.isEmphasized = isEmphasized
        }
    }
    public var title: String
    public var rows: [Row]
    public init(title: String = "", rows: [Row] = []) { self.title = title; self.rows = rows }
}

/// A footer action in a tooltip ("Drill down", "Drill through").
public struct TooltipAction: Identifiable {
    public let id = UUID()
    public var title: String
    public var systemImage: String
    public var action: () -> Void
    public init(title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.action = action
    }
}

/// Themed tooltip: header, aligned rows, optional footer actions. Follows the report theme, not the system appearance.
public struct TooltipCard: View {
    let content: TooltipContent
    let theme: ThemeSpec
    let actions: [TooltipAction]
    public init(content: TooltipContent, theme: ThemeSpec, actions: [TooltipAction] = []) {
        self.content = content; self.theme = theme; self.actions = actions
    }
    public var body: some View {
        let fg = theme.foregroundColor, sec = theme.secondaryColor
        VStack(alignment: .leading, spacing: 6) {
            if !content.title.isEmpty {
                Text(content.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(fg).lineLimit(2)
            }
            if !content.rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(content.rows) { row in
                        GridRow {
                            HStack(spacing: 6) {
                                if let c = row.color {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(c).frame(width: 8, height: 8)
                                }
                                Text(row.label).font(.system(size: 11)).foregroundStyle(sec).lineLimit(1)
                            }
                            Text(row.value).font(.system(size: 11, weight: row.isEmphasized ? .semibold : .medium).monospacedDigit())
                                .foregroundStyle(fg).lineLimit(1)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            if !actions.isEmpty {
                Rectangle().fill(theme.gridlineColor).frame(height: 0.5).padding(.top, 2)
                HStack(spacing: 10) {
                    ForEach(actions) { a in
                        Button(action: a.action) {
                            Label(a.title, systemImage: a.systemImage).font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accentColor)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.isDark ? Color(hex: theme.cardBackground).mix(with: .white, by: 0.08) : theme.cardColor)
                .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.16), radius: 12, y: 4)
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(theme.isHighContrast ? theme.foregroundColor : theme.gridlineColor.opacity(0.9), lineWidth: theme.isHighContrast ? 1 : 0.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Legend

public enum LegendPosition: String, CaseIterable, Sendable {
    case top, bottom, left, right
    public init(_ s: String) {
        let l = s.lowercased()
        if l.hasPrefix("bottom") { self = .bottom } else if l.hasPrefix("left") { self = .left }
        else if l.hasPrefix("right") { self = .right } else { self = .top }
    }
    var isHorizontal: Bool { self == .top || self == .bottom }
}

public struct LegendItem: Identifiable {
    public let id: Int
    public var name: String
    public var color: Color
    public var marker: MarkerShape
    /// Data point selected when the item is clicked (nil = item only highlights locally).
    public var selection: DataPointSelection?
    public init(id: Int, name: String, color: Color, marker: MarkerShape = .roundedSquare, selection: DataPointSelection? = nil) {
        self.id = id; self.name = name; self.color = color; self.marker = marker; self.selection = selection
    }
}

/// Wrapping legend. Horizontal positions flow and wrap to at most `maxLines`; vertical positions stack.
public struct LegendView: View {
    let items: [LegendItem]
    let position: LegendPosition
    let title: String
    let theme: ThemeSpec
    var fontSize: CGFloat
    /// Items drawn dimmed (not part of the current selection).
    var dimmed: Set<Int>
    let onTap: (LegendItem) -> Void

    public init(items: [LegendItem], position: LegendPosition = .top, title: String = "", theme: ThemeSpec,
                fontSize: CGFloat? = nil, dimmed: Set<Int> = [], onTap: @escaping (LegendItem) -> Void = { _ in }) {
        self.items = items; self.position = position; self.title = title; self.theme = theme
        self.fontSize = fontSize ?? CGFloat(theme.label.size); self.dimmed = dimmed; self.onTap = onTap
    }

    public var body: some View {
        Group {
            if position.isHorizontal {
                FlowLayout(spacing: 12, lineSpacing: 4, maxLines: 2) { content }
            } else {
                VStack(alignment: .leading, spacing: 5) { content }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Legend")
    }

    @ViewBuilder private var content: some View {
        if !title.isEmpty {
            Text(title).font(.system(size: fontSize, weight: .medium)).foregroundStyle(theme.foregroundColor).lineLimit(1)
        }
        ForEach(items) { item in
            Button { onTap(item) } label: {
                HStack(spacing: 5) {
                    MarkerView(shape: item.marker, color: item.color, size: 8)
                    Text(item.name).font(.system(size: fontSize)).foregroundStyle(theme.secondaryColor).lineLimit(1)
                }
                .opacity(dimmed.contains(item.id) ? 0.35 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.name)
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// Left-to-right wrapping layout with a line cap; overflowing children are hidden.
public struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4
    var maxLines: Int = .max
    public init(spacing: CGFloat = 8, lineSpacing: CGFloat = 4, maxLines: Int = .max) {
        self.spacing = spacing; self.lineSpacing = lineSpacing; self.maxLines = maxLines
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect?], size: CGSize) {
        var frames: [CGRect?] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, line = 0, maxX: CGFloat = 0
        for sv in subviews {
            var s = sv.sizeThatFits(.unspecified)
            s.width = min(s.width, width)
            if x > 0, x + s.width > width { x = 0; y += lineH + lineSpacing; lineH = 0; line += 1 }
            if line >= maxLines { frames.append(nil); continue }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: s))
            x += s.width + spacing; lineH = max(lineH, s.height); maxX = max(maxX, x - spacing)
        }
        return (frames, CGSize(width: maxX, height: y + lineH))
    }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 10_000).size
    }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let a = arrange(subviews, width: bounds.width)
        for (sv, f) in zip(subviews, a.frames) {
            if let f {
                sv.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
            } else {
                sv.place(at: CGPoint(x: -10_000, y: -10_000), proposal: .zero)
            }
        }
    }
}

/// Places a legend around a chart body according to `format["legend"]`, hides it when the visual is
/// small, and routes legend clicks: items with a `selection` call `context.onSelect`; others toggle a
/// local series highlight that the body receives as `highlighted`.
public struct ChartScaffold<Content: View>: View {
    let spec: VisualSpec
    let context: VisualContext
    let items: [LegendItem]
    /// Default visibility when `legend.show` is not set (usually `items.count > 1`).
    let defaultShow: Bool
    let content: (_ highlighted: Set<Int>) -> Content
    @State private var highlighted: Set<Int> = []

    public init(spec: VisualSpec, context: VisualContext, items: [LegendItem], defaultShow: Bool? = nil,
                @ViewBuilder content: @escaping (_ highlighted: Set<Int>) -> Content) {
        self.spec = spec; self.context = context; self.items = items
        self.defaultShow = defaultShow ?? (items.count > 1); self.content = content
    }

    public var body: some View {
        let f = ResolvedFormat(spec: spec, theme: context.theme)
        let position = LegendPosition(f.string("legend", "position", "top"))
        GeometryReader { geo in
            let show = f.bool("legend", "show", defaultShow) && !items.isEmpty && ChartSizeClass(geo.size).showLegend
            let legend = LegendView(items: items, position: position, title: f.string("legend", "title", ""),
                                    theme: context.theme, fontSize: CGFloat(f.double("legend", "size", context.theme.label.size)),
                                    dimmed: dimmed, onTap: tap)
            let body = content(highlighted).frame(maxWidth: .infinity, maxHeight: .infinity)
            Group {
                if !show { body } else {
                    switch position {
                    case .top:
                        VStack(alignment: .leading, spacing: Design.Space.s) { legend.frame(maxWidth: .infinity, alignment: .leading); body }
                    case .bottom:
                        VStack(alignment: .leading, spacing: Design.Space.s) { body; legend.frame(maxWidth: .infinity, alignment: .leading) }
                    case .left:
                        HStack(alignment: .top, spacing: Design.Space.m) {
                            legend.frame(maxWidth: min(160, geo.size.width * 0.3), maxHeight: .infinity, alignment: .topLeading).clipped(); body
                        }
                    case .right:
                        HStack(alignment: .top, spacing: Design.Space.m) {
                            body; legend.frame(maxWidth: min(160, geo.size.width * 0.3), maxHeight: .infinity, alignment: .topLeading).clipped()
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private var dimmed: Set<Int> {
        if !highlighted.isEmpty { return Set(items.map(\.id)).subtracting(highlighted) }
        guard !context.selection.isEmpty else { return [] }
        let selectable = items.filter { $0.selection != nil }
        let active = selectable.filter { item in context.selection.contains { $0.key == item.selection?.key } }
        return active.isEmpty ? [] : Set(selectable.map(\.id)).subtracting(active.map(\.id))
    }

    private func tap(_ item: LegendItem) {
        guard context.isInteractive else { return }
        let additive = NSEvent.modifierFlags.contains(.command)
        if let sel = item.selection {
            if context.isSelected(sel) && !additive && context.selection.count == 1 { context.onSelect([], false) }
            else { context.onSelect([sel], additive) }
        } else {
            withAnimation(Design.Motion.quick) {
                if additive { highlighted.formSymmetricDifference([item.id]) }
                else { highlighted = highlighted == [item.id] ? [] : [item.id] }
            }
        }
    }
}
