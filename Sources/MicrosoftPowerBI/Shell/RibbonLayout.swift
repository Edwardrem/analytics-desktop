import Foundation

// The ribbon as data. Nothing here draws or runs anything: `RibbonLayout.tabs` is the single table of
// tab → group → command ids, and the functions below decide which tabs show, how a group's items
// stack, and which ids the registry does not know yet. `Ribbon.swift` renders the result.

enum RibbonTabID: String, CaseIterable {
    case home, insert, modeling, view, optimize, help, externalTools
    // Contextual tabs.
    case format, dataDrill, tableTools, columnTools, measureTools, daxQuery, tmdl
}

/// One command on the ribbon: the registry id, the short caption drawn on the ribbon and its icon.
struct RibbonCommand: Equatable {
    var id: String
    var label: String
    var symbol: String
}

enum RibbonMenuEntry: Equatable {
    case command(RibbonCommand)
    case divider
}

enum RibbonControl: Equatable {
    /// Runs one command.
    case button(RibbonCommand)
    /// Drops a menu of commands.
    case menu(label: String, symbol: String, entries: [RibbonMenuEntry])
    /// Opens the gallery of every visual type (`insert.visual.<type>`).
    case visualGallery(label: String, symbol: String)
    /// One small button per registered command whose id starts with `prefix`, in registration order.
    /// This is how commands that do not exist yet in this build reach the ribbon without a layout change.
    case registered(prefix: String)
    /// A menu of the registered commands of these menus that the ribbon does not place anywhere else.
    case overflow(label: String, menus: [AppCommand.Menu])
}

struct RibbonItem: Equatable {
    enum Size { case large, small }
    var control: RibbonControl
    var size: Size
}

struct RibbonGroup: Equatable {
    var title: String
    var items: [RibbonItem]
}

/// What has to be true of the window for a contextual tab to show.
enum RibbonRequirement {
    case none
    /// One or more visuals are selected on the report page.
    case visualSelected
    /// Exactly one data visual (not a text box, shape, image or button) is selected.
    case dataVisualSelected
    /// A table is in context: Table view with a model, or a table, column or measure is selected.
    case tableContext
    case columnSelected
    case measureSelected
}

struct RibbonTab: Equatable {
    var id: RibbonTabID
    var title: String
    var contextual = false
    var views: Set<WorkspaceView> = Set(WorkspaceView.allCases)
    var requirement: RibbonRequirement = .none
    var groups: [RibbonGroup]
}

/// The facts about a window the ribbon needs to choose its tabs.
struct RibbonContext: Equatable {
    enum ModelObject { case table, column, measure }
    var view: WorkspaceView = .report
    /// Visuals selected on the current report page.
    var selectionCount = 0
    var dataVisualSelected = false
    /// The kind of model object selected in Table or Model view.
    var modelObject: ModelObject?
    var modelHasTables = false

    func satisfies(_ requirement: RibbonRequirement) -> Bool {
        switch requirement {
        case .none: return true
        case .visualSelected: return view == .report && selectionCount > 0
        case .dataVisualSelected: return view == .report && selectionCount == 1 && dataVisualSelected
        case .tableContext: return modelObject != nil || (view == .table && modelHasTables)
        case .columnSelected: return modelObject == .column
        case .measureSelected: return modelObject == .measure
        }
    }
}

/// What the ribbon needs to know about a registered command.
struct RibbonCommandInfo: Equatable {
    var id: String
    var title: String
    var symbol: String
    var menu: AppCommand.Menu
    var separatorBefore = false
}

/// A column of a group as drawn: one large control, or up to three small ones stacked.
enum RibbonColumn: Equatable {
    case large(RibbonItem)
    case stack([RibbonItem])
}

enum RibbonLayout {
    static let rowsPerColumn = 3
    static let visualPrefix = "insert.visual."
    /// Icon for a command that registers without one.
    static let fallbackSymbol = "circle.dashed"

    // MARK: - The table

    private static func large(_ id: String, _ label: String, _ symbol: String) -> RibbonItem {
        RibbonItem(control: .button(RibbonCommand(id: id, label: label, symbol: symbol)), size: .large)
    }
    private static func small(_ id: String, _ label: String, _ symbol: String) -> RibbonItem {
        RibbonItem(control: .button(RibbonCommand(id: id, label: label, symbol: symbol)), size: .small)
    }
    private static func entry(_ id: String, _ label: String, _ symbol: String) -> RibbonMenuEntry {
        .command(RibbonCommand(id: id, label: label, symbol: symbol))
    }
    private static func menu(_ label: String, _ symbol: String, size: RibbonItem.Size = .large, _ entries: [RibbonMenuEntry]) -> RibbonItem {
        RibbonItem(control: .menu(label: label, symbol: symbol, entries: entries), size: size)
    }
    private static func gallery() -> RibbonItem {
        RibbonItem(control: .visualGallery(label: "New visual", symbol: "chart.bar.xaxis"), size: .large)
    }
    private static func registered(_ prefix: String) -> RibbonItem {
        RibbonItem(control: .registered(prefix: prefix), size: .small)
    }
    private static func more(_ menus: [AppCommand.Menu]) -> RibbonGroup {
        RibbonGroup(title: "More", items: [RibbonItem(control: .overflow(label: "More", menus: menus), size: .large)])
    }

    private static let calculations = RibbonGroup(title: "Calculations", items: [
        large("model.newMeasure", "New measure", "function"),
        large("model.quickMeasure", "Quick measure", "wand.and.stars"),
        large("model.newColumn", "New column", "tablecells"),
        large("model.newTable", "New table", "table"),
    ])

    /// Every tab of the ribbon, in display order: tab → group → command ids.
    /// Ids that are not registered draw disabled; `unregisteredIDs(in:)` lists them.
    static let tabs: [RibbonTab] = [
        RibbonTab(id: .home, title: "Home", groups: [
            RibbonGroup(title: "Clipboard", items: [
                large("edit.paste", "Paste", "doc.on.clipboard"),
                small("edit.cut", "Cut", "scissors"),
                small("edit.copy", "Copy", "doc.on.doc"),
                small("edit.formatPainter", "Format painter", "paintbrush.pointed"),
            ]),
            RibbonGroup(title: "Data", items: [
                menu("Get data", "cylinder.split.1x2", [
                    entry("data.get", "Get Data…", "cylinder.split.1x2"),
                    entry("data.enter", "Enter Data…", "square.and.pencil"),
                    entry("data.recent", "Recent Sources…", "clock"),
                    .divider,
                    entry("account.catalog", "OneLake Catalog…", "books.vertical"),
                    entry("data.sample", "Load Sample Data", "shippingbox"),
                ]),
                small("account.catalog", "OneLake catalog", "books.vertical"),
                small("data.enter", "Enter data", "square.and.pencil"),
                small("data.recent", "Recent sources", "clock"),
            ]),
            RibbonGroup(title: "Queries", items: [
                large("data.transform", "Transform data", "wand.and.rays"),
                large("data.refresh", "Refresh", "arrow.triangle.2.circlepath"),
            ]),
            RibbonGroup(title: "Insert", items: [
                gallery(),
                large("insert.textBox", "Text box", "textformat"),
            ]),
            RibbonGroup(title: "Calculations", items: [
                large("model.newMeasure", "New measure", "function"),
                large("model.quickMeasure", "Quick measure", "wand.and.stars"),
            ]),
            RibbonGroup(title: "Sensitivity", items: [
                large("account.sensitivity", "Sensitivity", "lock.doc"),
            ]),
            RibbonGroup(title: "Share", items: [
                large("account.publish", "Publish", "square.and.arrow.up"),
            ]),
            RibbonGroup(title: "Assistant", items: [
                large("view.pane.assistant", "Assistant", "sparkles"),
            ]),
            more([.edit, .data]),
        ]),

        RibbonTab(id: .insert, title: "Insert", views: [.report], groups: [
            RibbonGroup(title: "Pages", items: [
                menu("New page", "plus.rectangle", [
                    entry("insert.page", "Blank Page", "plus.rectangle"),
                    entry("insert.duplicatePage", "Duplicate Page", "plus.rectangle.on.rectangle"),
                    entry("insert.tooltipPage", "Tooltip Page", "text.bubble"),
                ]),
            ]),
            RibbonGroup(title: "Visuals", items: [gallery()]),
            RibbonGroup(title: "AI visuals", items: [
                small("insert.visual.qna", "Q&A", "questionmark.bubble"),
                small("insert.visual.keyInfluencers", "Key influencers", "arrow.up.arrow.down.circle"),
                small("insert.visual.decompositionTree", "Decomposition tree", "arrow.triangle.branch"),
                small("insert.visual.narrative", "Narrative", "text.alignleft"),
            ]),
            RibbonGroup(title: "Power Platform", items: [
                small("insert.visual.powerApps", "Power Apps", "app.badge"),
                small("insert.visual.powerAutomate", "Power Automate", "bolt.horizontal"),
                small("insert.visual.paginatedReport", "Paginated report", "doc.text"),
            ]),
            RibbonGroup(title: "Elements", items: [
                large("insert.textBox", "Text box", "textformat"),
                menu("Buttons", "button.horizontal", [
                    entry("insert.button", "Blank Button", "button.horizontal"),
                    entry("insert.pageNavigator", "Page Navigator", "rectangle.split.3x1"),
                    entry("insert.bookmarkNavigator", "Bookmark Navigator", "bookmark.square"),
                    .divider,
                    entry("optimize.applyAllSlicers", "Apply All Slicers Button", "checkmark.rectangle"),
                    entry("optimize.clearAllSlicersButton", "Clear All Slicers Button", "xmark.rectangle"),
                ]),
                large("insert.shape", "Shapes", "square.on.circle"),
                large("insert.image", "Image", "photo"),
            ]),
            RibbonGroup(title: "Bookmarks", items: [
                large("bookmarks.add", "Add bookmark", "bookmark"),
            ]),
            RibbonGroup(title: "Sparklines", items: [
                large("insert.sparkline", "Add a sparkline", "waveform.path.ecg"),
            ]),
            more([.insert]),
        ]),

        RibbonTab(id: .modeling, title: "Modeling", groups: [
            RibbonGroup(title: "Relationships", items: [
                large("model.relationships", "Manage relationships", "arrow.left.arrow.right"),
                large("model.autodetectRelationships", "Autodetect", "sparkle.magnifyingglass"),
            ]),
            calculations,
            RibbonGroup(title: "Parameters", items: [
                large("model.newParameter", "New parameter", "slider.horizontal.3"),
            ]),
            RibbonGroup(title: "Security", items: [
                large("model.roles", "Manage roles", "lock.shield"),
                large("model.viewAs", "View as", "person.crop.rectangle"),
            ]),
            RibbonGroup(title: "Q&A", items: [
                small("model.qnaSetup", "Q&A setup", "questionmark.bubble"),
                small("model.synonyms", "Synonyms", "character.book.closed"),
                small("model.translations", "Translations", "globe"),
            ]),
            RibbonGroup(title: "Calculation groups", items: [
                large("model.calculationGroups", "Calculation groups", "square.stack.3d.up"),
                large("model.functions", "Functions", "curlybraces"),
            ]),
            more([.modeling]),
        ]),

        RibbonTab(id: .view, title: "View", views: [.report], groups: [
            RibbonGroup(title: "Themes", items: [
                large("view.pane.theme", "Themes", "swatchpalette"),
                small("theme.import", "Browse for themes", "square.and.arrow.down"),
                small("theme.export", "Save current theme", "square.and.arrow.up"),
                small("page.settings", "Page settings", "doc.badge.gearshape"),
            ]),
            RibbonGroup(title: "Scale to fit", items: [
                menu("Page view", "arrow.up.left.and.arrow.down.right", [
                    entry("view.fit", "Fit to Page", "arrow.up.left.and.arrow.down.right"),
                    entry("view.actualSize", "Actual Size", "1.magnifyingglass"),
                    .divider,
                    entry("view.zoomIn", "Zoom In", "plus.magnifyingglass"),
                    entry("view.zoomOut", "Zoom Out", "minus.magnifyingglass"),
                ]),
            ]),
            RibbonGroup(title: "Mobile", items: [
                large("view.mobile", "Mobile layout", "iphone"),
            ]),
            RibbonGroup(title: "Page options", items: [
                small("view.gridlines", "Gridlines", "grid"),
                small("view.snap", "Snap to grid", "square.grid.3x3.middle.filled"),
                small("view.lock", "Lock objects", "lock"),
            ]),
            RibbonGroup(title: "Show panes", items: [
                small("view.pane.filters", "Filters", "line.3.horizontal.decrease"),
                small("view.pane.build", "Visualizations", "square.grid.2x2"),
                small("view.pane.data", "Data", "cylinder.split.1x2"),
                small("view.pane.bookmarks", "Bookmarks", "bookmark"),
                small("view.pane.selection", "Selection", "square.3.layers.3d"),
                small("view.pane.performance", "Performance analyzer", "gauge.with.needle"),
                small("view.pane.syncSlicers", "Sync slicers", "arrow.triangle.2.circlepath"),
                small("view.pane.format", "Format", "paintbrush"),
                small("view.inspector", "All panes", "sidebar.right"),
            ]),
            RibbonGroup(title: "Present", items: [
                large("view.present", "Present", "play.rectangle"),
                small("bookmarks.view", "Play bookmarks", "play"),
                small("view.ribbon", "Collapse ribbon", "rectangle.topthird.inset.filled"),
                small("view.palette", "Commands", "command"),
            ]),
            more([.view]),
        ]),

        RibbonTab(id: .optimize, title: "Optimize", views: [.report], groups: [
            RibbonGroup(title: "Queries", items: [
                large("optimize.pause", "Pause visuals", "pause"),
                large("optimize.refreshVisuals", "Refresh visuals", "arrow.clockwise"),
            ]),
            RibbonGroup(title: "Presets", items: [
                menu("Optimization presets", "dial.medium", [
                    entry("optimize.presetReduction", "Query Reduction", "tortoise"),
                    entry("optimize.presetInteractive", "Full Interactivity", "hare"),
                ]),
            ]),
            // As on Windows, this group inserts the two buttons; it does not act on the slicers itself.
            RibbonGroup(title: "Insert slicer buttons", items: [
                large("optimize.applyAllSlicers", "Apply all slicers button", "checkmark.rectangle"),
                large("optimize.clearAllSlicersButton", "Clear all slicers button", "xmark.rectangle"),
            ]),
            RibbonGroup(title: "Selections", items: [
                large("optimize.clearSlicers", "Clear selections now", "xmark.circle"),
            ]),
            RibbonGroup(title: "Diagnostics", items: [
                large("optimize.performance", "Performance analyzer", "gauge.with.needle"),
            ]),
            more([.optimize]),
        ]),

        RibbonTab(id: .help, title: "Help", groups: [
            RibbonGroup(title: "Learn", items: [
                large("help.dax", "DAX reference", "function"),
                large("help.powerQuery", "Power Query M reference", "wand.and.rays"),
                large("help.shortcuts", "Keyboard shortcuts", "keyboard"),
            ]),
            RibbonGroup(title: "Get started", items: [
                large("data.sample", "Sample data", "shippingbox"),
            ]),
            RibbonGroup(title: "Account", items: [
                small("account.signIn", "Sign in", "person.crop.circle"),
                small("account.signOut", "Sign out", "person.crop.circle.badge.xmark"),
                small("account.saveToOneDrive", "Save to OneDrive", "cloud"),
            ]),
            RibbonGroup(title: "About", items: [
                large("help.about", "About", "info.circle"),
            ]),
            more([.help, .account]),
        ]),

        RibbonTab(id: .externalTools, title: "External tools", groups: [
            RibbonGroup(title: "Tools", items: [registered("externalTools.tool.")]),
            RibbonGroup(title: "Manage", items: [
                large("externalTools.openFolder", "Tools folder", "folder"),
                large("externalTools.reload", "Reload tools", "arrow.clockwise"),
            ]),
            more([.tools]),
        ]),

        // Contextual

        RibbonTab(id: .format, title: "Format", contextual: true, views: [.report], requirement: .visualSelected, groups: [
            RibbonGroup(title: "Arrange", items: [
                menu("Bring forward", "square.2.layers.3d.top.filled", [
                    entry("format.forward", "Bring Forward", "square.2.layers.3d.top.filled"),
                    entry("format.front", "Bring to Front", "square.3.layers.3d.top.filled"),
                ]),
                menu("Send backward", "square.2.layers.3d.bottom.filled", [
                    entry("format.backward", "Send Backward", "square.2.layers.3d.bottom.filled"),
                    entry("format.back", "Send to Back", "square.3.layers.3d.bottom.filled"),
                ]),
                large("view.pane.selection", "Selection", "square.3.layers.3d"),
                menu("Align", "align.horizontal.left", [
                    entry("format.alignLeft", "Align Left", "align.horizontal.left"),
                    entry("format.alignCenter", "Align Center", "align.horizontal.center"),
                    entry("format.alignRight", "Align Right", "align.horizontal.right"),
                    .divider,
                    entry("format.alignTop", "Align Top", "align.vertical.top"),
                    entry("format.alignMiddle", "Align Middle", "align.vertical.center"),
                    entry("format.alignBottom", "Align Bottom", "align.vertical.bottom"),
                    .divider,
                    entry("format.distributeH", "Distribute Horizontally", "distribute.horizontal"),
                    entry("format.distributeV", "Distribute Vertically", "distribute.vertical"),
                ]),
                menu("Match size", "square.resize", [
                    entry("format.sameWidth", "Match Width", "arrow.left.and.right"),
                    entry("format.sameHeight", "Match Height", "arrow.up.and.down"),
                    entry("format.sameSize", "Match Size", "square.resize"),
                ]),
                menu("Group", "square.on.square.dashed", [
                    entry("format.group", "Group", "square.on.square.dashed"),
                    entry("format.ungroup", "Ungroup", "square.dashed"),
                ]),
            ]),
            RibbonGroup(title: "Interactions", items: [
                large("format.editInteractions", "Edit interactions", "arrow.left.arrow.right"),
            ]),
            RibbonGroup(title: "Style", items: [
                large("view.pane.format", "Format pane", "paintbrush"),
                large("edit.formatPainter", "Format painter", "paintbrush.pointed"),
            ]),
            RibbonGroup(title: "Edit", items: [
                small("edit.duplicate", "Duplicate", "plus.square.on.square"),
                small("edit.delete", "Delete", "trash"),
                small("page.settings", "Page settings", "doc.badge.gearshape"),
            ]),
            more([.format]),
        ]),

        RibbonTab(id: .dataDrill, title: "Data / Drill", contextual: true, views: [.report], requirement: .dataVisualSelected, groups: [
            RibbonGroup(title: "Show", items: [
                large("drill.showAsTable", "Visual table", "tablecells"),
                large("drill.focus", "Focus mode", "arrow.up.left.and.arrow.down.right"),
            ]),
            RibbonGroup(title: "Drill actions", items: [
                large("drill.up", "Drill up", "arrow.up"),
                large("drill.nextLevel", "Next level", "arrow.down.to.line"),
                large("drill.expand", "Expand next level", "arrow.triangle.branch"),
            ]),
            RibbonGroup(title: "Analyze", items: [
                small("analyze.quickInsights", "Quick insights", "wand.and.stars"),
                small("analyze.explainChange", "Explain the change", "chart.line.uptrend.xyaxis"),
                small("analyze.distribution", "Find differences", "percent"),
            ]),
            RibbonGroup(title: "Export", items: [
                small("drill.exportData", "Export data", "square.and.arrow.up"),
                small("drill.copyImage", "Copy as image", "photo.on.rectangle"),
            ]),
        ]),

        RibbonTab(id: .tableTools, title: "Table tools", contextual: true, views: [.table, .model], requirement: .tableContext, groups: [
            RibbonGroup(title: "Table", items: [registered("model.table.")]),
            RibbonGroup(title: "Calendars", items: [
                large("model.markDateTable", "Mark as date table", "calendar"),
            ]),
            RibbonGroup(title: "Relationships", items: [
                large("model.relationships", "Manage relationships", "arrow.left.arrow.right"),
            ]),
            calculations,
        ]),

        RibbonTab(id: .columnTools, title: "Column tools", contextual: true, views: [.table, .model], requirement: .columnSelected, groups: [
            RibbonGroup(title: "Column", items: [registered("model.column.")]),
            RibbonGroup(title: "Sort", items: [
                large("model.sortByColumn", "Sort by column", "arrow.up.arrow.down"),
            ]),
            RibbonGroup(title: "Groups", items: [
                large("model.newGroup", "Data groups", "square.stack.3d.up"),
                large("model.newHierarchy", "New hierarchy", "list.bullet.indent"),
            ]),
            RibbonGroup(title: "Relationships", items: [
                large("model.relationships", "Manage relationships", "arrow.left.arrow.right"),
            ]),
            RibbonGroup(title: "Calculations", items: [
                large("model.newColumn", "New column", "tablecells"),
            ]),
        ]),

        RibbonTab(id: .measureTools, title: "Measure tools", contextual: true, views: [.table, .model], requirement: .measureSelected, groups: [
            RibbonGroup(title: "Measure", items: [registered("model.measure.")]),
            RibbonGroup(title: "Calculations", items: [
                large("model.newMeasure", "New measure", "function"),
                large("model.quickMeasure", "Quick measure", "wand.and.stars"),
            ]),
        ]),

        RibbonTab(id: .daxQuery, title: "DAX query", contextual: true, views: [.dax], groups: [
            RibbonGroup(title: "Query", items: [
                large("dax.run", "Run", "play"),
                large("dax.newTab", "New query", "plus.square.on.square"),
                large("dax.format", "Format query", "text.alignleft"),
            ]),
            RibbonGroup(title: "Quick queries", items: [
                menu("Quick queries", "bolt", [
                    entry("dax.quick.top100", "Show Top 100 Rows", "list.number"),
                    entry("dax.quick.columnStats", "Show Column Statistics", "chart.bar"),
                    .divider,
                    entry("dax.quick.defineMeasure", "Define and Evaluate Measure", "function"),
                    entry("dax.quick.defineWithReferences", "Define with References and Evaluate", "function"),
                    entry("dax.quick.defineAll", "Define All Measures in This Model", "function"),
                ]),
            ]),
            RibbonGroup(title: "Model", items: [
                large("dax.updateModel", "Update model", "arrow.up.doc"),
                large("dax.export", "Export results", "square.and.arrow.up"),
            ]),
        ]),

        RibbonTab(id: .tmdl, title: "TMDL", contextual: true, views: [.tmdl], groups: [
            RibbonGroup(title: "Script", items: [registered("tmdl.")]),
        ]),
    ]

    // MARK: - Auditing the table

    private static func commands(in item: RibbonItem) -> [RibbonCommand] {
        switch item.control {
        case .button(let c): return [c]
        case .menu(_, _, let entries):
            return entries.compactMap { if case .command(let c) = $0 { return c } else { return nil } }
        case .visualGallery, .registered, .overflow: return []
        }
    }

    /// Every command id the table names, sorted and without repeats.
    static let referencedIDs: [String] =
        Array(Set(tabs.flatMap { $0.groups.flatMap { $0.items.flatMap(commands(in:)).map(\.id) } })).sorted()
    /// Prefixes whose commands are picked up as they register.
    static let registeredPrefixes: [String] =
        tabs.flatMap { $0.groups.flatMap { $0.items.compactMap { item -> String? in
            if case .registered(let p) = item.control { return p } else { return nil }
        } } }
    /// Ids the ribbon names that the registry does not have: these draw disabled.
    static func unregisteredIDs(in registered: Set<String>) -> [String] {
        referencedIDs.filter { !registered.contains($0) }
    }

    /// True when the ribbon reaches this command without help from a "More" menu.
    static func placesDirectly(_ id: String) -> Bool {
        if id.hasPrefix(visualPrefix) { return true }
        if registeredPrefixes.contains(where: { id.hasPrefix($0) }) { return true }
        return referencedSet.contains(id)
    }
    private static let referencedSet = Set(referencedIDs)

    /// The commands a "More" menu lists: registered in one of `menus` and placed nowhere else.
    static func overflow(menus: [AppCommand.Menu], registry: [RibbonCommandInfo]) -> [RibbonCommandInfo] {
        var seen = Set<String>()
        return registry.filter { menus.contains($0.menu) && !placesDirectly($0.id) && seen.insert($0.id).inserted }
    }

    // MARK: - Resolving against the registry

    /// Replaces the registry-driven controls of a group with concrete buttons and menus.
    static func expand(_ group: RibbonGroup, registry: [RibbonCommandInfo]) -> RibbonGroup {
        var items: [RibbonItem] = []
        for item in group.items {
            switch item.control {
            case .registered(let prefix):
                var seen = Set<String>()
                for info in registry where info.id.hasPrefix(prefix) && seen.insert(info.id).inserted {
                    let symbol = info.symbol.isEmpty ? fallbackSymbol : info.symbol
                    items.append(RibbonItem(control: .button(RibbonCommand(id: info.id, label: info.title, symbol: symbol)), size: item.size))
                }
            case .overflow(let label, let menus):
                let extra = overflow(menus: menus, registry: registry)
                guard !extra.isEmpty else { continue }
                var entries: [RibbonMenuEntry] = []
                for (i, info) in extra.enumerated() {
                    if info.separatorBefore, i > 0 { entries.append(.divider) }
                    entries.append(.command(RibbonCommand(id: info.id, label: info.title, symbol: info.symbol)))
                }
                items.append(RibbonItem(control: .menu(label: label, symbol: "ellipsis.circle", entries: entries), size: item.size))
            default:
                items.append(item)
            }
        }
        return RibbonGroup(title: group.title, items: items)
    }

    /// A tab with its registry-driven groups resolved; groups left with nothing are dropped.
    static func expand(_ tab: RibbonTab, registry: [RibbonCommandInfo]) -> RibbonTab {
        var t = tab
        t.groups = tab.groups.map { expand($0, registry: registry) }.filter { !$0.items.isEmpty }
        return t
    }

    /// The tabs to show, in order: those that belong to the view and whose requirement holds.
    /// A tab that resolves to no groups (nothing registered for it yet) is left out.
    static func visibleTabs(_ context: RibbonContext, registry: [RibbonCommandInfo]) -> [RibbonTab] {
        visibleTabs(context, resolved: resolve(registry: registry))
    }

    /// Every tab resolved against a registry, empty ones dropped. This depends only on the set of
    /// commands, so it is computed once per registry generation (`RibbonRegistry.resolved`).
    static func resolve(registry: [RibbonCommandInfo]) -> [RibbonTab] {
        tabs.map { expand($0, registry: registry) }.filter { !$0.groups.isEmpty }
    }

    /// The per-render part: pick the already-resolved tabs that belong to this window state.
    static func visibleTabs(_ context: RibbonContext, resolved: [RibbonTab]) -> [RibbonTab] {
        resolved.filter { $0.views.contains(context.view) && context.satisfies($0.requirement) }
    }

    /// The tab to draw: the chosen one while it is visible, otherwise the first (Home).
    static func activeTab(selected: RibbonTabID, visible: [RibbonTab]) -> RibbonTab? {
        visible.first { $0.id == selected } ?? visible.first
    }

    /// Stacks a group's items into columns: large controls stand alone, small ones stack three high.
    static func columns(_ group: RibbonGroup) -> [RibbonColumn] {
        var out: [RibbonColumn] = []
        var run: [RibbonItem] = []
        func flush() {
            var i = 0
            while i < run.count {
                out.append(.stack(Array(run[i..<min(i + rowsPerColumn, run.count)])))
                i += rowsPerColumn
            }
            run = []
        }
        for item in group.items {
            if item.size == .large { flush(); out.append(.large(item)) } else { run.append(item) }
        }
        flush()
        return out
    }

    /// The File menu: every File command, in registration order, split where the registry asks.
    static func fileMenu(registry: [RibbonCommandInfo]) -> [RibbonMenuEntry] {
        var entries: [RibbonMenuEntry] = []
        var seen = Set<String>()
        for info in registry where info.menu == .file && seen.insert(info.id).inserted {
            if info.separatorBefore, !entries.isEmpty { entries.append(.divider) }
            entries.append(.command(RibbonCommand(id: info.id, label: info.title, symbol: info.symbol)))
        }
        return entries
    }
}
