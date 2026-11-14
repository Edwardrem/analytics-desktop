import SwiftUI
import FacetCore
import FacetDesign

/// Lightweight (id, name) pair for page and bookmark navigators.
public struct NavItem: Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
}

/// A command the host adds to a visual's context menu.
public struct VisualMenuAction: Identifiable {
    public let id: String
    public var title: String
    public var perform: () -> Void
    public init(title: String, perform: @escaping () -> Void) { self.id = title; self.title = title; self.perform = perform }
}

/// Everything a visual needs from its host besides its spec and data.
/// Renderers are pure views: they never touch the model, they only call back.
public struct VisualContext {
    public var theme: ThemeSpec = .facet
    /// False while the author is arranging the canvas with visuals paused, or in thumbnails/exports.
    public var isInteractive = true
    /// Data points of *this* visual currently selected (drives its own emphasis state).
    public var selection: [DataPointSelection] = []
    public var overlays = AnalyticsOverlays()
    public var pages: [NavItem] = []
    public var bookmarks: [NavItem] = []
    public var currentPageID: UUID?
    public var activeBookmarkID: UUID?
    /// Select data points. Empty array clears. `additive` is true for ⌘-click.
    public var onSelect: (_ points: [DataPointSelection], _ additive: Bool) -> Void = { _, _ in }
    public var onSlicerChange: (SlicerState) -> Void = { _ in }
    public var onAction: (ActionSpec) -> Void = { _ in }
    public var onDrill: (DrillAction) -> Void = { _ in }
    /// Persist a change the visual made to its own spec (column widths, matrix expansion, sort, text edits).
    public var onSpecChange: (VisualSpec) -> Void = { _ in }
    /// Host-supplied renderer for visuals implemented outside this module (AI visuals, scripted visuals).
    public var extensionView: ((VisualSpec, VisualData, VisualContext) -> AnyView?)?
    /// Modern visual tooltips: drill and drillthrough actions in the tooltip footer.
    public var modernTooltips = true
    /// A report page tooltip for the hovered data point, shown instead of the default tooltip card when non-nil.
    public var pageTooltip: ((DataPointSelection) -> AnyView?)?
    /// Pages the data point can drill through to (empty = no drillthrough offered).
    public var drillthroughTargets: (DataPointSelection) -> [NavItem] = { _ in [] }
    /// Whether a button's action can run right now (a drillthrough button needs a valid selection).
    public var canRunAction: (ActionSpec) -> Bool = { _ in true }
    /// Show the underlying records of a data point, when the host can.
    public var onSeeRecords: ((DataPointSelection) -> Void)?
    /// The report asks every slicer for an Apply button (query reduction); a slicer's own
    /// `format["slicer"]["applyButton"]` still wins.
    public var slicerApplyButtons = false
    /// Analyze commands the host offers for a data point ("Explain the increase"), listed under
    /// Analyze in the point's context menu. Empty = no Analyze menu.
    public var analyzeActions: (DataPointSelection) -> [VisualMenuAction] = { _ in [] }

    public init() {}

    public func isSelected(_ p: DataPointSelection) -> Bool { selection.contains { $0.key == p.key } }
    /// Opacity for a mark given the current selection: selected or nothing selected = 1, otherwise dimmed.
    public func emphasis(_ p: DataPointSelection) -> Double { selection.isEmpty || isSelected(p) ? 1 : 0.3 }
}

/// The single entry point for drawing any visual: container chrome (background, border, shadow,
/// title, subtitle, divider, padding) around the type-specific body.
public struct VisualView: View {
    public let spec: VisualSpec
    public let data: VisualData
    public let context: VisualContext

    /// Draws `spec` with its measure-driven format values (`data.formatOverrides`) in place of the
    /// stored ones. A change the renderer reports keeps the stored values of the properties it
    /// left alone, so an evaluated value is never written back as a static one.
    public init(spec: VisualSpec, data: VisualData, context: VisualContext) {
        let overrides = spec.boundFormatOverrides(data.formatOverrides)
        self.data = data
        guard !overrides.isEmpty else { self.spec = spec; self.context = context; return }
        self.spec = spec.applyingFormatOverrides(overrides)
        var c = context
        let report = context.onSpecChange
        c.onSpecChange = { edited in report(edited.restoringFormatOverrides(overrides, from: spec)) }
        self.context = c
    }

    public var body: some View {
        let theme = context.theme
        let f = ResolvedFormat(spec: spec, theme: theme)
        let radius = f.double("border", "radius", spec.type.isPageElement ? 0 : theme.cornerRadius)
        let padding = f.double("padding", "all", spec.type.isPageElement ? 0 : theme.visualPadding)
        let showBackground = f.bool("background", "show", !spec.type.isPageElement)
        let bg = Color(hex: f.string("background", "color", theme.cardBackground))
            .opacity(1 - f.double("background", "transparency", 0) / 100)
        VStack(alignment: .leading, spacing: 0) {
            if f.bool("title", "show", !spec.type.isPageElement && !spec.type.isSlicer || (spec.type.isSlicer && true)),
               !titleText(f).isEmpty {
                VStack(alignment: alignment(f.string("title", "alignment", "left")), spacing: 2) {
                    Text(titleText(f))
                        .font(.system(size: f.double("title", "size", theme.title.size),
                                      weight: f.bool("title", "bold", true) ? .semibold : .regular))
                        .foregroundStyle(Color(hex: f.string("title", "color", theme.foreground)))
                        .lineLimit(2)
                    if f.bool("subtitle", "show", false) {
                        Text(f.string("subtitle", "text", ""))
                            .font(.system(size: f.double("subtitle", "size", theme.label.size)))
                            .foregroundStyle(Color(hex: f.string("subtitle", "color", theme.secondaryForeground)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment(f.string("title", "alignment", "left")), vertical: .center))
                .padding(.bottom, Design.Space.s)
                if f.bool("divider", "show", false) {
                    Rectangle().fill(Color(hex: f.string("divider", "color", theme.gridline))).frame(height: 1)
                        .padding(.bottom, Design.Space.s)
                }
            }
            bodyView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(padding)
        .background(showBackground ? bg : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            if f.bool("border", "show", false) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color(hex: f.string("border", "color", theme.gridline)), lineWidth: f.double("border", "width", 1))
            }
        }
        .shadow(color: f.bool("shadow", "show", false) ? .black.opacity(0.12) : .clear, radius: 10, y: 3)
        // A visual sits on its theme's card, not on the window: system text colours inside it follow
        // the theme, or a light report is unreadable (white on white) while the Mac is in Dark Mode.
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spec.altText.isEmpty ? spec.name : spec.altText)
    }

    private func titleText(_ f: ResolvedFormat) -> String {
        if let t = data.dynamicTitle, !t.isEmpty { return t }
        if let t = spec.fmt("title", "text")?.stringValue { return t }
        if spec.type.isPageElement { return "" }
        return VisualTitles.automatic(for: spec)
    }
    private func alignment(_ s: String) -> HorizontalAlignment {
        switch s { case "center": return .center; case "right": return .trailing; default: return .leading }
    }

    @ViewBuilder private var bodyView: some View {
        if let error = data.error, !spec.type.isPageElement {
            EmptyState(systemImage: "exclamationmark.triangle", title: "Can't display this visual", message: error)
        } else if let v = context.extensionView?(spec, data, context) {
            v
        } else if let v = ChartVisuals.view(spec: spec, data: data, context: context) {
            v
        } else if let v = ComponentVisuals.view(spec: spec, data: data, context: context) {
            v
        } else {
            EmptyState(systemImage: "square.dashed", title: spec.type.displayName, message: "Add fields to build this visual.")
        }
    }
}

/// Format lookup with fallbacks: visual → theme defaults for the type → theme defaults for "*" → caller default.
public struct ResolvedFormat {
    public let spec: VisualSpec
    public let theme: ThemeSpec
    public init(spec: VisualSpec, theme: ThemeSpec) { self.spec = spec; self.theme = theme }

    public func value(_ card: String, _ key: String) -> JSONValue? {
        spec.format[card]?[key]
            ?? theme.visualDefaults[spec.type.rawValue]?[card]?[key]
            ?? theme.visualDefaults["*"]?[card]?[key]
    }
    public func bool(_ card: String, _ key: String, _ d: Bool) -> Bool { value(card, key)?.boolValue ?? d }
    public func double(_ card: String, _ key: String, _ d: Double) -> Double { value(card, key)?.doubleValue ?? d }
    public func string(_ card: String, _ key: String, _ d: String) -> String { value(card, key)?.stringValue ?? d }
    public func color(_ card: String, _ key: String, _ d: String) -> Color { Color(hex: string(card, key, d)) }
}

public enum VisualTitles {
    /// "Sales by Region and Year" style automatic title.
    public static func automatic(for spec: VisualSpec) -> String {
        if spec.type.isSlicer { return spec.fields(.field).first?.caption ?? "" }
        let valueWells: [Well] = [.values, .lineValues, .y, .x, .size, .analyze]
        let values = valueWells.flatMap { spec.fields($0) }.filter { !$0.isHidden }.map(\.caption)
        let groupWells: [Well] = [.category, .rows, .columns, .legend, .details, .location, .task, .source, .destination, .trendAxis, .breakdown]
        let groups = groupWells.flatMap { spec.fields($0) }.map(\.caption)
        func list(_ a: [String]) -> String {
            a.count <= 2 ? a.joined(separator: " and ") : a.dropLast().joined(separator: ", ") + " and " + a.last!
        }
        switch (values.isEmpty, groups.isEmpty) {
        case (true, true): return ""
        case (false, true): return list(values)
        case (true, false): return list(groups)
        case (false, false): return "\(list(values)) by \(list(groups))"
        }
    }
}
