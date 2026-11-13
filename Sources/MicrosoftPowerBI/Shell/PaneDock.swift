import Foundation

// The right-hand panes as data. `PaneDock` records which panes are open, collapsed and how wide;
// `columns(for:available:)` turns that into what is drawn for a given window width.
// `PaneDockView.swift` renders the result; the panes themselves come from `Features.pane`.

/// A column of the dock. The order of the cases is the order on screen, left to right.
enum DockSlot: String, CaseIterable, Codable, Hashable {
    case filters, extras, visualizations, data

    var title: String {
        switch self {
        case .filters: return "Filters"
        case .extras: return "Panes"
        case .visualizations: return "Visualizations"
        case .data: return "Data"
        }
    }
    var defaultWidth: Double {
        switch self {
        case .filters: return 260
        case .extras, .visualizations: return 300
        case .data: return 270
        }
    }
}

/// One column of the dock as drawn.
struct DockColumn: Equatable {
    var slot: DockSlot
    var width: Double
    var collapsed: Bool
    /// Collapsed by the layout to keep the canvas usable, not by the user.
    var automatic = false
}

struct PaneDock: Codable, Equatable {
    static let widthRange: ClosedRange<Double> = 240...520
    /// Width of a collapsed, labelled strip.
    static let stripWidth: Double = 30
    /// The canvas never gets narrower than this while a pane can still be collapsed.
    static let minimumCanvas: Double = 340
    /// The canvas the default arrangement aims for. With all three panes at their default widths
    /// this is a window of about 1300 pt; below it Filters starts as its strip.
    static let comfortableCanvas: Double = 420
    /// Panes that only mean something in Report view.
    static let reportOnly: Set<String> = [
        InspectorPane.bookmarks.rawValue, InspectorPane.selection.rawValue, InspectorPane.syncSlicers.rawValue,
        InspectorPane.performance.rawValue, InspectorPane.theme.rawValue,
    ]

    /// Fixed columns closed from the View tab.
    var hidden: Set<DockSlot> = []
    var collapsed: Set<DockSlot> = []
    /// The pane showing in the Visualizations column: Build or Format.
    var visualizationsPane = InspectorPane.build.rawValue
    /// Extra panes (Bookmarks, Selection…), in the order they were opened. They share one column.
    var openExtras: [String] = []
    var activeExtra: String?
    var widths: [String: Double] = [:]
    /// Columns in the order they were last asked for; the most recent are the last to give way.
    var recency: [DockSlot] = []

    init() {}

    // Decoding tolerates settings written by an older or newer build.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hidden = Set((try? c.decode([String].self, forKey: .hidden))?.compactMap(DockSlot.init(rawValue:)) ?? [])
        collapsed = Set((try? c.decode([String].self, forKey: .collapsed))?.compactMap(DockSlot.init(rawValue:)) ?? [])
        visualizationsPane = (try? c.decode(String.self, forKey: .visualizationsPane)) ?? InspectorPane.build.rawValue
        if PaneDock.slot(for: visualizationsPane) != .visualizations { visualizationsPane = InspectorPane.build.rawValue }
        openExtras = ((try? c.decode([String].self, forKey: .openExtras)) ?? []).filter { PaneDock.slot(for: $0) == .extras }
        activeExtra = try? c.decode(String.self, forKey: .activeExtra)
        widths = (try? c.decode([String: Double].self, forKey: .widths)) ?? [:]
        recency = ((try? c.decode([String].self, forKey: .recency)) ?? []).compactMap(DockSlot.init(rawValue:))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
        try c.encode(collapsed.map(\.rawValue).sorted(), forKey: .collapsed)
        try c.encode(visualizationsPane, forKey: .visualizationsPane)
        try c.encode(openExtras, forKey: .openExtras)
        try c.encodeIfPresent(activeExtra, forKey: .activeExtra)
        try c.encode(widths, forKey: .widths)
        try c.encode(recency.map(\.rawValue), forKey: .recency)
    }
    private enum CodingKeys: String, CodingKey { case hidden, collapsed, visualizationsPane, openExtras, activeExtra, widths, recency }

    // MARK: - Where panes live

    /// The column a pane (an `InspectorPane` raw value) belongs to. Panes this build has never heard
    /// of — ones a feature adds later — share the extras column.
    static func slot(for pane: String) -> DockSlot {
        switch pane {
        case InspectorPane.filters.rawValue: return .filters
        case InspectorPane.build.rawValue, InspectorPane.format.rawValue: return .visualizations
        case InspectorPane.data.rawValue: return .data
        default: return .extras
        }
    }

    /// The extra panes open in a view, in the order they were opened.
    func extras(for view: WorkspaceView) -> [String] {
        view == .report ? openExtras : openExtras.filter { !PaneDock.reportOnly.contains($0) }
    }
    /// The extra pane on show in a view.
    func activeExtra(for view: WorkspaceView) -> String? {
        let open = extras(for: view)
        if let a = activeExtra, open.contains(a) { return a }
        return open.last
    }

    /// The columns a view shows, left to right. Report view has the three Windows panes; Table and
    /// Model view keep Data; the code views keep only the extra panes that are not about the report.
    func slots(for view: WorkspaceView) -> [DockSlot] {
        let fixed = PaneDock.fixedSlots(in: view)
        return DockSlot.allCases.filter { slot in
            slot == .extras ? !extras(for: view).isEmpty : (fixed.contains(slot) && !hidden.contains(slot))
        }
    }

    /// The pane a column is showing.
    func pane(in slot: DockSlot, view: WorkspaceView) -> String? {
        switch slot {
        case .filters: return InspectorPane.filters.rawValue
        case .visualizations: return visualizationsPane
        case .data: return InspectorPane.data.rawValue
        case .extras: return activeExtra(for: view)
        }
    }

    /// The fixed columns a view has room for in principle.
    static func fixedSlots(in view: WorkspaceView) -> [DockSlot] {
        switch view {
        case .report: return [.filters, .visualizations, .data]
        case .table, .model: return [.data]
        case .dax, .tmdl: return []
        }
    }

    /// Whether a pane can be shown in a view at all. Its switch is disabled when it cannot.
    static func isAvailable(_ pane: String, in view: WorkspaceView) -> Bool {
        let slot = slot(for: pane)
        if slot == .extras { return view == .report || !reportOnly.contains(pane) }
        return fixedSlots(in: view).contains(slot)
    }

    /// True when the pane is actually drawn, expanded, in this view at this width: its column is
    /// there, is not a strip (whether the user or the layout collapsed it), and it is the pane in front.
    func isShowing(_ pane: String, view: WorkspaceView, available: Double) -> Bool {
        let slot = PaneDock.slot(for: pane)
        guard let column = columns(for: view, available: available).first(where: { $0.slot == slot }),
              !column.collapsed else { return false }
        return self.pane(in: slot, view: view) == pane
    }

    /// True when two arrangements differ at most in pane widths.
    func sameArrangement(as other: PaneDock) -> Bool {
        var a = self, b = other
        a.widths = [:]; b.widths = [:]
        return a == b
    }

    // MARK: - Changing it

    /// Marks a column as the one most recently asked for, so it is the last to give way.
    mutating func bringForward(_ slot: DockSlot) {
        recency.removeAll { $0 == slot }
        recency.append(slot)
    }

    /// Opens a pane, expands its column and brings it to the front of that column.
    mutating func reveal(_ pane: String) {
        let slot = PaneDock.slot(for: pane)
        hidden.remove(slot)
        collapsed.remove(slot)
        switch slot {
        case .visualizations: visualizationsPane = pane
        case .extras:
            if !openExtras.contains(pane) { openExtras.append(pane) }
            activeExtra = pane
        case .filters, .data: break
        }
        bringForward(slot)
    }

    /// Closes a pane. Build and Format close the Visualizations column they share.
    mutating func close(_ pane: String) {
        let slot = PaneDock.slot(for: pane)
        if slot == .extras {
            openExtras.removeAll { $0 == pane }
            if activeExtra == pane { activeExtra = openExtras.last }
        } else {
            hidden.insert(slot)
        }
    }

    /// Collapses a column to its strip, or expands it again.
    mutating func setCollapsed(_ slot: DockSlot, _ value: Bool) {
        if value { collapsed.insert(slot) } else { collapsed.remove(slot); bringForward(slot) }
    }

    /// The widest a column may be dragged in this view and window: what is left once the canvas has
    /// its minimum and the other columns keep the widths they are drawn at. Never below the minimum width.
    func maximumWidth(of slot: DockSlot, view: WorkspaceView, available: Double) -> Double {
        let others = columns(for: view, available: available).filter { $0.slot != slot }.reduce(0) { $0 + $1.width }
        let budget = available - PaneDock.minimumCanvas - others
        return min(PaneDock.widthRange.upperBound, max(PaneDock.widthRange.lowerBound, budget))
    }
    /// Sets a width while dragging: clamped so the drag cannot push the canvas under its minimum,
    /// which would otherwise collapse a pane (possibly the one being dragged).
    mutating func setWidth(_ width: Double, of slot: DockSlot, view: WorkspaceView, available: Double) {
        guard width.isFinite else { return }
        setWidth(min(width, maximumWidth(of: slot, view: view, available: available)), of: slot)
    }

    func width(of slot: DockSlot) -> Double {
        let w = widths[slot.rawValue] ?? slot.defaultWidth
        return min(max(w, PaneDock.widthRange.lowerBound), PaneDock.widthRange.upperBound)
    }
    mutating func setWidth(_ width: Double, of slot: DockSlot) {
        guard width.isFinite else { return }
        widths[slot.rawValue] = min(max(width, PaneDock.widthRange.lowerBound), PaneDock.widthRange.upperBound)
    }

    // MARK: - Layout

    /// The columns to draw in `available` points (the window width right of the view rail).
    /// When the open panes would squeeze the canvas below `minimumCanvas`, the columns asked for
    /// longest ago collapse to strips first; the user's own choices are not changed.
    func columns(for view: WorkspaceView, available: Double) -> [DockColumn] {
        var columns = slots(for: view).map { slot -> DockColumn in
            let isCollapsed = collapsed.contains(slot)
            return DockColumn(slot: slot, width: isCollapsed ? PaneDock.stripWidth : width(of: slot), collapsed: isCollapsed)
        }
        // A Filters pane the user has never asked for starts as its strip when the default panes
        // would leave the page too small to work on. Default widths decide, so dragging a pane
        // wider never folds another one away.
        if !recency.contains(.filters), let i = columns.firstIndex(where: { $0.slot == .filters && !$0.collapsed }) {
            let defaults = columns.reduce(0) { $0 + ($1.collapsed ? $1.width : $1.slot.defaultWidth) }
            if available - defaults < PaneDock.comfortableCanvas {
                columns[i] = DockColumn(slot: .filters, width: PaneDock.stripWidth, collapsed: true, automatic: true)
            }
        }
        // Give way in this order: never-touched columns in Windows order of importance, then by age.
        let untouched: [DockSlot] = [.filters, .extras, .data, .visualizations].filter { !recency.contains($0) }
        for slot in untouched + recency {
            let used = columns.reduce(0) { $0 + $1.width }
            if available - used >= PaneDock.minimumCanvas { break }
            guard let i = columns.firstIndex(where: { $0.slot == slot && !$0.collapsed }) else { continue }
            columns[i] = DockColumn(slot: slot, width: PaneDock.stripWidth, collapsed: true, automatic: true)
        }
        return columns
    }
}
