import SwiftUI
import FacetCore

/// One user-invocable action. Every command appears in the menu bar and in the command
/// palette (⌘K); toolbars and buttons run the same commands by id, so behaviour never forks.
struct AppCommand: Identifiable {
    enum Menu: String, CaseIterable { case file = "File", edit = "Edit", insert = "Insert", data = "Data", modeling = "Modeling", format = "Format", view = "View", optimize = "Optimize", account = "Account", tools = "External Tools", help = "Help" }
    var id: String
    var title: String
    var menu: Menu
    var symbol: String = ""
    var shortcut: KeyboardShortcut?
    /// Starts a new menu section before this item.
    var separatorBefore = false
    /// Extra tooltip text, shown after the title (for example an external tool's description).
    var help = ""
    var isEnabled: @MainActor (DocumentStore) -> Bool = { _ in true }
    var isOn: (@MainActor (DocumentStore) -> Bool)?
    var run: @MainActor (DocumentStore) -> Void
}

@MainActor
enum AppCommands {
    /// Command providers. Feature areas append their own in `registerAll()`.
    static var providers: [() -> [AppCommand]] = [CoreCommands.commands, ExternalTools.commands]
    private static var cache: [AppCommand]?
    private static var index: [String: AppCommand] = [:]
    /// Bumped whenever the set of commands may have changed, so views can cache what they derive from it.
    private(set) static var generation = 0

    static var all: [AppCommand] {
        if let cache { return cache }
        let list = providers.flatMap { $0() }
        cache = list
        // The first registration of an id wins, as it always has.
        index = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return list
    }
    static func register(_ provider: @escaping () -> [AppCommand]) { providers.append(provider); invalidate() }
    /// Rebuild the command list on next use (a provider's commands changed, e.g. external tools were reloaded).
    static func invalidate() { cache = nil; generation += 1 }
    static func command(_ id: String) -> AppCommand? { _ = all; return index[id] }
    static func run(_ id: String, _ store: DocumentStore) {
        guard let c = command(id) else {
            store.status = StatusMessage(kind: .warning, text: "“\(id)” isn't available yet.")
            return
        }
        perform(c, store)
    }
    /// The one way a command runs — from the ribbon, the menu bar, a shortcut or the palette — so
    /// window chrome that reacts to "a command ran" (a peeking ribbon) always hears about it.
    static func perform(_ c: AppCommand, _ store: DocumentStore) {
        guard c.isEnabled(store) else { return }
        ShellState.of(store).commandWillRun()
        c.run(store)
    }
}

@MainActor
enum CoreCommands {
    static func commands() -> [AppCommand] {
        var c: [AppCommand] = []
        let hasSelection: @MainActor (DocumentStore) -> Bool = { !$0.selection.isEmpty && $0.view == .report }

        // File
        c.append(AppCommand(id: "file.open", title: "Open…", menu: .file, symbol: "folder", shortcut: .init("o")) { FileOperations.open(into: $0) })
        c.append(AppCommand(id: "file.save", title: "Save", menu: .file, symbol: "square.and.arrow.down", shortcut: .init("s"), separatorBefore: true) { FileOperations.save($0) })
        c.append(AppCommand(id: "file.saveAs", title: "Save As…", menu: .file, shortcut: .init("s", modifiers: [.command, .shift])) { FileOperations.saveAs($0) })
        c.append(AppCommand(id: "file.revert", title: "Revert to Saved", menu: .file, isEnabled: { $0.fileURL != nil && $0.isDirty }) { FileOperations.revert($0) })
        c.append(AppCommand(id: "file.exportPDF", title: "Export to PDF…", menu: .file, symbol: "doc.richtext", separatorBefore: true) { VisualExport.exportPDF($0) })

        // Edit
        c.append(AppCommand(id: "edit.undo", title: "Undo", menu: .edit, symbol: "arrow.uturn.backward", shortcut: .init("z"), isEnabled: { $0.undoName != nil }) { $0.undo() })
        c.append(AppCommand(id: "edit.redo", title: "Redo", menu: .edit, symbol: "arrow.uturn.forward", shortcut: .init("z", modifiers: [.command, .shift]), isEnabled: { $0.redoName != nil }) { $0.redo() })
        c.append(AppCommand(id: "edit.cut", title: "Cut Visual", menu: .edit, shortcut: .init("x", modifiers: [.command, .option]), separatorBefore: true, isEnabled: hasSelection) { $0.cutSelection() })
        c.append(AppCommand(id: "edit.copy", title: "Copy Visual", menu: .edit, shortcut: .init("c", modifiers: [.command, .option]), isEnabled: hasSelection) { $0.copySelection() })
        c.append(AppCommand(id: "edit.paste", title: "Paste Visual", menu: .edit, shortcut: .init("v", modifiers: [.command, .option]), isEnabled: { $0.view == .report }) { $0.paste() })
        c.append(AppCommand(id: "edit.duplicate", title: "Duplicate", menu: .edit, shortcut: .init("d"), isEnabled: hasSelection) { $0.duplicateSelection() })
        c.append(AppCommand(id: "edit.delete", title: "Delete", menu: .edit, symbol: "trash", shortcut: .init(.delete, modifiers: [.command]), isEnabled: hasSelection) { $0.deleteSelection() })
        c.append(AppCommand(id: "edit.selectAll", title: "Select All Visuals", menu: .edit, shortcut: .init("a", modifiers: [.command, .option]), separatorBefore: true, isEnabled: { $0.view == .report }) {
            $0.selection = Set($0.currentPage.visuals.filter { !$0.isHidden }.map(\.id))
        })
        c.append(AppCommand(id: "edit.formatPainter", title: "Format Painter", menu: .edit, symbol: "paintbrush.pointed", isEnabled: { $0.selectedVisual != nil }) {
            $0.formatPainterSource = $0.selectedVisual?.id
            $0.status = StatusMessage(kind: .info, text: "Click another visual to apply this formatting.")
        })

        // Insert: pages and elements
        c.append(AppCommand(id: "insert.page", title: "New Page", menu: .insert, symbol: "plus.rectangle", shortcut: .init("n", modifiers: [.command, .option])) { $0.view = .report; $0.addPage() })
        c.append(AppCommand(id: "insert.tooltipPage", title: "New Tooltip Page", menu: .insert) { $0.view = .report; $0.addPage(named: "Tooltip", tooltip: true) })
        c.append(AppCommand(id: "insert.duplicatePage", title: "Duplicate Page", menu: .insert) { $0.duplicatePage($0.currentPageID) })
        let elements: [(String, VisualType, String, Bool)] = [
            ("insert.textBox", .textBox, "textformat", true), ("insert.button", .button, "button.horizontal", false),
            ("insert.shape", .shape, "square.on.circle", false), ("insert.image", .image, "photo", false),
            ("insert.pageNavigator", .pageNavigator, "rectangle.split.3x1", false),
            ("insert.bookmarkNavigator", .bookmarkNavigator, "bookmark.square", false),
        ]
        for (id, type, symbol, sep) in elements {
            c.append(AppCommand(id: id, title: type.displayName, menu: .insert, symbol: symbol, separatorBefore: sep) { s in
                s.view = .report
                if type == .image { VisualExport.insertImage(s) } else {
                    s.addVisual(type) { v in
                        if type == .textBox { v.content = "Text" }
                        if type == .button { v.setFmt("button", "text", .string("Button")) }
                    }
                }
            })
        }
        var first = true
        for type in VisualType.allCases where !type.isPageElement {
            c.append(AppCommand(id: "insert.visual.\(type.rawValue)", title: type.displayName, menu: .insert,
                                symbol: VisualCatalog.symbol(for: type), separatorBefore: first) { s in
                s.view = .report
                if let v = s.selectedVisual, !v.type.isPageElement, v.allFields.isEmpty || NSEvent.modifierFlags.contains(.option) {
                    s.changeType(of: v.id, to: type)
                } else { s.addVisual(type) }
            })
            first = false
        }

        // Format: arrange
        let arrangements: [(String, String, DocumentStore.Arrangement, String)] = [
            ("format.alignLeft", "Align Left", .left, "align.horizontal.left"), ("format.alignCenter", "Align Center", .centerH, "align.horizontal.center"),
            ("format.alignRight", "Align Right", .right, "align.horizontal.right"), ("format.alignTop", "Align Top", .top, "align.vertical.top"),
            ("format.alignMiddle", "Align Middle", .centerV, "align.vertical.center"), ("format.alignBottom", "Align Bottom", .bottom, "align.vertical.bottom"),
            ("format.distributeH", "Distribute Horizontally", .distributeH, "distribute.horizontal"),
            ("format.distributeV", "Distribute Vertically", .distributeV, "distribute.vertical"),
            ("format.sameWidth", "Match Width", .sameWidth, ""), ("format.sameHeight", "Match Height", .sameHeight, ""), ("format.sameSize", "Match Size", .sameSize, ""),
        ]
        for (id, title, a, symbol) in arrangements {
            c.append(AppCommand(id: id, title: title, menu: .format, symbol: symbol,
                                separatorBefore: id == "format.distributeH" || id == "format.sameWidth", isEnabled: hasSelection) { $0.arrange(a) })
        }
        c.append(AppCommand(id: "format.front", title: "Bring to Front", menu: .format, shortcut: .init("]", modifiers: [.command, .shift]), separatorBefore: true, isEnabled: hasSelection) { $0.reorder(.front) })
        c.append(AppCommand(id: "format.forward", title: "Bring Forward", menu: .format, shortcut: .init("]"), isEnabled: hasSelection) { $0.reorder(.forward) })
        c.append(AppCommand(id: "format.backward", title: "Send Backward", menu: .format, shortcut: .init("["), isEnabled: hasSelection) { $0.reorder(.backward) })
        c.append(AppCommand(id: "format.back", title: "Send to Back", menu: .format, shortcut: .init("[", modifiers: [.command, .shift]), isEnabled: hasSelection) { $0.reorder(.back) })
        c.append(AppCommand(id: "format.group", title: "Group", menu: .format, shortcut: .init("g"), separatorBefore: true, isEnabled: { $0.selection.count > 1 }) { $0.groupSelection() })
        c.append(AppCommand(id: "format.ungroup", title: "Ungroup", menu: .format, shortcut: .init("g", modifiers: [.command, .shift]), isEnabled: { $0.selectedVisuals.contains { $0.groupID != nil } }) { $0.ungroupSelection() })
        c.append(AppCommand(id: "format.editInteractions", title: "Edit Interactions", menu: .format, symbol: "arrow.left.arrow.right", separatorBefore: true,
                            isEnabled: { InteractionRules.canEdit($0.selectedVisual) || $0.editInteractionsFor != nil }, isOn: { $0.editInteractionsFor != nil }) {
            $0.editInteractionsFor = $0.editInteractionsFor == nil ? $0.selectedVisual?.id : nil
        })

        // View
        for (i, v) in WorkspaceView.allCases.enumerated() {
            c.append(AppCommand(id: "view.\(v.rawValue)", title: "\(v.title) View", menu: .view, symbol: v.symbol,
                                shortcut: .init(KeyEquivalent(Character("\(i + 1)"))), isOn: { $0.view == v }) { $0.view = v })
        }
        c.append(AppCommand(id: "view.inspector", title: "Show Panes", menu: .view, symbol: "sidebar.right", shortcut: .init("i", modifiers: [.command, .option]), separatorBefore: true, isOn: { $0.inspectorVisible }) { $0.inspectorVisible.toggle() })
        c.append(AppCommand(id: "view.ribbon", title: "Collapse Ribbon", menu: .view, symbol: "rectangle.topthird.inset.filled",
                            shortcut: .init("r", modifiers: [.command, .option]), isOn: { ShellState.of($0).ribbonCollapsed }) {
            ShellState.of($0).toggleRibbon()
        })
        // Pane switches: each shows its pane in the dock, or closes it when it is already showing.
        for (i, p) in InspectorPane.allCases.enumerated() {
            c.append(AppCommand(id: "view.pane.\(p.rawValue)", title: "\(p.title) Pane", menu: .view, symbol: p.symbol,
                                shortcut: i < 9 ? .init(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option]) : nil,
                                separatorBefore: i == 0,
                                isEnabled: { ShellState.of($0).isAvailable(p) },
                                isOn: { ShellState.of($0).isShowing(p) }) { ShellState.of($0).toggle(p) })
        }
        c.append(AppCommand(id: "view.fit", title: "Fit to Page", menu: .view, shortcut: .init("0"), separatorBefore: true, isOn: { $0.fitToWindow && !$0.fitToWidth }) { $0.fitToWidth = false; $0.fitToWindow = true })
        c.append(AppCommand(id: "view.actualSize", title: "Actual Size", menu: .view, shortcut: .init("0", modifiers: [.command, .option]),
                            isOn: { !$0.fitToWindow && $0.zoom == 1 }) { $0.fitToWindow = false; $0.zoom = 1 })
        c.append(AppCommand(id: "view.zoomIn", title: "Zoom In", menu: .view, shortcut: .init("+")) { $0.fitToWindow = false; $0.zoom = min(4, $0.zoom * 1.2) })
        c.append(AppCommand(id: "view.zoomOut", title: "Zoom Out", menu: .view, shortcut: .init("-")) { $0.fitToWindow = false; $0.zoom = max(0.1, $0.zoom / 1.2) })
        c.append(AppCommand(id: "view.gridlines", title: "Gridlines", menu: .view, symbol: "grid", separatorBefore: true, isOn: { $0.showGridlines }) { $0.showGridlines.toggle() })
        c.append(AppCommand(id: "view.snap", title: "Snap to Grid", menu: .view, isOn: { $0.snapToGrid }) { $0.snapToGrid.toggle() })
        c.append(AppCommand(id: "view.lock", title: "Lock Objects", menu: .view, symbol: "lock", isOn: { $0.lockObjects }) { $0.lockObjects.toggle() })
        c.append(AppCommand(id: "view.mobile", title: "Mobile Layout", menu: .view, symbol: "iphone", isOn: { $0.mobileLayout }) { $0.mobileLayout.toggle(); $0.selection = [] })
        c.append(AppCommand(id: "view.present", title: "Present", menu: .view, symbol: "play.rectangle", shortcut: .init(.return, modifiers: [.command, .option]), separatorBefore: true) { $0.view = .report; $0.selection = []; $0.presenting = true })
        c.append(AppCommand(id: "view.palette", title: "Command Palette…", menu: .view, symbol: "command", shortcut: .init("k")) { store in
            // Addressed to this document's window; every window hears the notification.
            NotificationCenter.default.post(name: .facetShowPalette, object: store)
        })

        // Optimize
        c.append(AppCommand(id: "optimize.pause", title: "Pause Visuals", menu: .optimize, symbol: "pause", isOn: { $0.visualsPaused }) { $0.visualsPaused.toggle() })
        c.append(AppCommand(id: "optimize.refreshVisuals", title: "Refresh Visuals", menu: .optimize, symbol: "arrow.clockwise", shortcut: .init("r", modifiers: [.command, .shift])) { s in
            let paused = s.visualsPaused
            if paused { s.visualsPaused = false; s.visualsPaused = true } else { s.refreshVisuals() }
        })
        c.append(AppCommand(id: "optimize.presetReduction", title: "Preset: Query Reduction", menu: .optimize, separatorBefore: true) { s in
            s.mutate("Apply Query Reduction") { d in
                d.report.settings.disableCrossHighlightByDefault = true
                d.report.settings.slicerApplyButtons = true
                d.report.settings.filterPaneApplyButton = true
            }
            s.status = StatusMessage(kind: .success, text: "Cross-highlighting is off; slicers and filters now use Apply buttons.")
        })
        c.append(AppCommand(id: "optimize.presetInteractive", title: "Preset: Full Interactivity", menu: .optimize) { s in
            s.mutate("Apply Full Interactivity") { d in
                d.report.settings.disableCrossHighlightByDefault = false
                d.report.settings.slicerApplyButtons = false
                d.report.settings.filterPaneApplyButton = false
            }
        })
        c.append(AppCommand(id: "optimize.performance", title: "Performance Analyzer", menu: .optimize, symbol: "gauge.with.needle", separatorBefore: true) { $0.inspector = .performance; $0.inspectorVisible = true })
        c.append(AppCommand(id: "optimize.clearSlicers", title: "Clear Slicer Selections Now", menu: .optimize, symbol: "xmark.circle") { $0.clearAllSlicers() })
        // Buttons that apply or clear every slicer on the page, for reports that use query reduction.
        let slicerButtons: [(String, String, String, ActionSpec.Kind, String)] = [
            ("optimize.applyAllSlicers", "Add Apply All Slicers Button", "Apply all slicers", .applyAllSlicers, "checkmark.rectangle"),
            ("optimize.clearAllSlicersButton", "Add Clear All Slicers Button", "Clear all slicers", .clearAllSlicers, "xmark.rectangle"),
        ]
        for (id, title, caption, kind, symbol) in slicerButtons {
            c.append(AppCommand(id: id, title: title, menu: .optimize, symbol: symbol, separatorBefore: kind == .applyAllSlicers,
                                isEnabled: { $0.view == .report }) { s in
                s.addVisual(.button) { v in
                    v.setFmt("button", "text", .string(caption))
                    var action = ActionSpec()
                    action.kind = kind
                    v.action = action
                }
            })
        }

        // Drill and data actions for the one selected data visual (the Data / Drill tab).
        let dataVisual: @MainActor (DocumentStore) -> VisualSpec? = { s in
            guard s.view == .report, let v = s.selectedVisual, !v.type.isPageElement else { return nil }
            return v
        }
        let drillLevels: (VisualSpec) -> Int = { v in v.fields(.category).count + (v.type == .matrix ? v.fields(.rows).count : 0) }
        c.append(AppCommand(id: "drill.showAsTable", title: "Show as Table", menu: .data, symbol: "tablecells", separatorBefore: true,
                            isEnabled: { dataVisual($0) != nil }) { s in
            if let v = dataVisual(s) { s.drill(.showAsTable, in: v.id) }
        })
        c.append(AppCommand(id: "drill.focus", title: "Focus Mode", menu: .data, symbol: "arrow.up.left.and.arrow.down.right",
                            isEnabled: { dataVisual($0) != nil }) { s in
            if let v = dataVisual(s) { s.focusVisualID = v.id }
        })
        c.append(AppCommand(id: "drill.up", title: "Drill Up", menu: .data, symbol: "arrow.up",
                            isEnabled: { (dataVisual($0)?.drillLevel ?? 0) > 0 }) { s in
            if let v = dataVisual(s) { s.drill(.up, in: v.id) }
        })
        c.append(AppCommand(id: "drill.nextLevel", title: "Go to the Next Level", menu: .data, symbol: "arrow.down.to.line",
                            isEnabled: { s in dataVisual(s).map { $0.drillLevel < drillLevels($0) - 1 } ?? false }) { s in
            if let v = dataVisual(s) { s.drill(.down(nil), in: v.id) }
        })
        c.append(AppCommand(id: "drill.expand", title: "Expand All Down One Level", menu: .data, symbol: "arrow.triangle.branch",
                            isEnabled: { s in dataVisual(s).map { $0.drillLevel < $0.fields(.category).count - 1 } ?? false }) { s in
            if let v = dataVisual(s) { s.drill(.expandAll, in: v.id) }
        })
        c.append(AppCommand(id: "drill.exportData", title: "Export Visual Data…", menu: .data, symbol: "square.and.arrow.up",
                            isEnabled: { dataVisual($0) != nil }) { s in
            if let v = dataVisual(s) { VisualExport.exportData(of: v, store: s, format: "csv") }
        })
        c.append(AppCommand(id: "drill.copyImage", title: "Copy Visual as Image", menu: .data, symbol: "photo.on.rectangle",
                            isEnabled: { $0.view == .report && $0.selectedVisual != nil }) { s in
            if let v = s.selectedVisual { VisualExport.copyImage(of: v, store: s) }
        })

        // Data (basics; Get Data, Transform, etc. are registered by the data feature)
        c.append(AppCommand(id: "data.refresh", title: "Refresh", menu: .data, symbol: "arrow.triangle.2.circlepath", shortcut: .init("r")) { $0.refreshData() })
        c.append(AppCommand(id: "data.sample", title: "Load Sample Data", menu: .data, symbol: "shippingbox") { SampleData.install(into: $0) })

        // Help
        let references: [(String, String, String, String)] = [
            ("help.dax", "DAX Reference", "function", "https://learn.microsoft.com/dax/"),
            ("help.powerQuery", "Power Query M Reference", "wand.and.rays", "https://learn.microsoft.com/powerquery-m/"),
        ]
        for (id, title, symbol, address) in references {
            c.append(AppCommand(id: id, title: title, menu: .help, symbol: symbol) { s in
                guard let url = URL(string: address), NSWorkspace.shared.open(url) else {
                    s.status = StatusMessage(kind: .error, text: "Couldn't open \(address) in your browser.")
                    return
                }
            })
        }
        c.append(AppCommand(id: "help.shortcuts", title: "Keyboard Shortcuts", menu: .help, symbol: "keyboard", separatorBefore: true) { s in
            s.present { KeyboardShortcutsSheet() }
        })
        c.append(AppCommand(id: "help.about", title: "About \(AppIdentity.name)", menu: .help, symbol: "info.circle") { _ in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        return c
    }
}

extension Notification.Name {
    static let facetShowPalette = Notification.Name("facet.showPalette")
}

/// Icons and grouping for the visual gallery.
enum VisualCatalog {
    static let groups: [(name: String, types: [VisualType])] = [
        ("Comparison", [.clusteredColumn, .stackedColumn, .stackedColumn100, .clusteredBar, .stackedBar, .stackedBar100, .bullet, .radar]),
        ("Trend", [.line, .area, .stackedArea, .stackedArea100, .lineClusteredColumn, .lineStackedColumn, .ribbon, .candlestick, .calendarHeatmap]),
        ("Part to whole", [.pie, .donut, .treemap, .sunburst, .funnel, .waterfall, .sankey]),
        ("Distribution", [.scatter, .dotPlot, .histogram, .boxPlot, .heatmap, .wordCloud]),
        ("Single value", [.card, .cardLegacy, .multiRowCard, .kpi, .gauge]),
        ("Tables", [.table, .matrix]),
        ("Slicers", [.slicer, .buttonSlicer, .listSlicer, .inputSlicer]),
        ("Maps", [.azureMap, .map, .filledMap, .shapeMap]),
        ("Insight", [.keyInfluencers, .decompositionTree, .narrative, .qna]),
        ("More", [.gantt, .pythonVisual, .rVisual, .paginatedReport, .powerApps, .powerAutomate, .metrics]),
    ]
    static func symbol(for t: VisualType) -> String {
        switch t {
        case .stackedBar, .clusteredBar, .stackedBar100: return "chart.bar.xaxis"
        case .stackedColumn, .clusteredColumn, .stackedColumn100: return "chart.bar"
        case .line: return "chart.xyaxis.line"
        case .area, .stackedArea, .stackedArea100: return "chart.line.uptrend.xyaxis"
        case .lineStackedColumn, .lineClusteredColumn: return "chart.bar.xaxis.ascending"
        case .ribbon: return "wave.3.right"
        case .waterfall: return "chart.bar.xaxis.ascending.badge.clock"
        case .pie: return "chart.pie"
        case .donut: return "circle.circle"
        case .treemap: return "rectangle.split.2x2"
        case .funnel: return "line.3.horizontal.decrease"
        case .scatter: return "chart.dots.scatter"
        case .dotPlot: return "circle.grid.3x3"
        case .map, .azureMap: return "map"
        case .filledMap, .shapeMap: return "globe.europe.africa"
        case .card, .cardLegacy: return "textformat.123"
        case .multiRowCard: return "rectangle.grid.1x2"
        case .kpi: return "arrow.up.right"
        case .gauge: return "gauge.with.needle"
        case .table: return "tablecells"
        case .matrix: return "tablecells.badge.ellipsis"
        case .slicer, .listSlicer: return "checklist"
        case .buttonSlicer: return "rectangle.grid.3x2"
        case .inputSlicer: return "character.cursor.ibeam"
        case .keyInfluencers: return "arrow.up.arrow.down.circle"
        case .decompositionTree: return "arrow.triangle.branch"
        case .narrative: return "text.alignleft"
        case .qna: return "questionmark.bubble"
        case .gantt: return "chart.bar.doc.horizontal"
        case .pythonVisual, .rVisual: return "chevron.left.forwardslash.chevron.right"
        case .paginatedReport: return "doc.text"
        case .powerApps: return "app.badge"
        case .powerAutomate: return "bolt.horizontal"
        case .metrics: return "target"
        case .textBox: return "textformat"
        case .image: return "photo"
        case .shape: return "square.on.circle"
        case .button: return "button.horizontal"
        case .pageNavigator: return "rectangle.split.3x1"
        case .bookmarkNavigator: return "bookmark.square"
        case .heatmap: return "square.grid.3x3.fill"
        case .histogram: return "chart.bar.fill"
        case .boxPlot: return "align.vertical.center"
        case .radar: return "hexagon"
        case .sunburst: return "sun.max"
        case .sankey: return "arrow.triangle.merge"
        case .bullet: return "minus.rectangle"
        case .calendarHeatmap: return "calendar"
        case .wordCloud: return "textformat.size"
        case .candlestick: return "chart.bar.xaxis.ascending"
        }
    }
}
