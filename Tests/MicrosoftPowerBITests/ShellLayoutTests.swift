import XCTest
import AppKit
import SwiftUI
import FacetCore
@testable import MicrosoftPowerBI

// MARK: - Ribbon layout

@MainActor
final class RibbonLayoutTests: XCTestCase {
    /// Ribbon ids that no feature registers yet. They draw disabled. When a feature registers one,
    /// remove it here; the test only fails if an id goes missing that is not on this list.
    static let pending: Set<String> = [
        "account.sensitivity", "insert.sparkline",
    ]

    override func setUp() {
        super.setUp()
        Features.registerAll()
    }

    private func info(_ id: String, _ menu: AppCommand.Menu = .modeling, title: String = "T", separator: Bool = false) -> RibbonCommandInfo {
        RibbonCommandInfo(id: id, title: title, symbol: "", menu: menu, separatorBefore: separator)
    }
    private func ids(_ tabs: [RibbonTab]) -> [RibbonTabID] { tabs.map(\.id) }

    func testTableIsWellFormed() {
        XCTAssertEqual(Set(RibbonLayout.tabs.map(\.id)).count, RibbonLayout.tabs.count, "tab ids repeat")
        for tab in RibbonLayout.tabs {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertFalse(tab.groups.isEmpty, "\(tab.id) has no groups")
            XCTAssertFalse(tab.views.isEmpty, "\(tab.id) shows in no view")
            for group in tab.groups {
                XCTAssertFalse(group.title.isEmpty)
                XCTAssertFalse(group.items.isEmpty, "\(tab.id)/\(group.title) is empty")
            }
        }
        XCTAssertEqual(RibbonLayout.tabs.filter { !$0.contextual }.map(\.title),
                       ["Home", "Insert", "Modeling", "View", "Optimize", "Help", "External tools"])
    }

    func testMainTabsInReportViewWithNothingSelected() {
        let tabs = RibbonLayout.visibleTabs(RibbonContext(view: .report), registry: RibbonRegistry.infos)
        XCTAssertEqual(ids(tabs), [.home, .insert, .modeling, .view, .optimize, .help, .externalTools])
    }

    func testContextualTabsFollowTheSelection() {
        let registry = RibbonRegistry.infos
        var c = RibbonContext(view: .report, selectionCount: 1, dataVisualSelected: true)
        XCTAssertEqual(Array(ids(RibbonLayout.visibleTabs(c, registry: registry)).suffix(2)), [.format, .dataDrill])
        c.dataVisualSelected = false          // a text box
        XCTAssertTrue(ids(RibbonLayout.visibleTabs(c, registry: registry)).contains(.format))
        XCTAssertFalse(ids(RibbonLayout.visibleTabs(c, registry: registry)).contains(.dataDrill))
        c.selectionCount = 3                  // several visuals: arrange, but no drill
        c.dataVisualSelected = true
        XCTAssertFalse(ids(RibbonLayout.visibleTabs(c, registry: registry)).contains(.dataDrill))
        // A selection in Report view means nothing once you leave it.
        c.view = .table
        XCTAssertFalse(ids(RibbonLayout.visibleTabs(c, registry: registry)).contains(.format))
    }

    func testModelingToolsTabs() {
        let registry = RibbonRegistry.infos
        var c = RibbonContext(view: .table, modelHasTables: true)
        XCTAssertEqual(ids(RibbonLayout.visibleTabs(c, registry: registry)), [.home, .modeling, .help, .externalTools, .tableTools])
        c.modelObject = .column
        XCTAssertEqual(Array(ids(RibbonLayout.visibleTabs(c, registry: registry)).suffix(2)), [.tableTools, .columnTools])
        c.modelObject = .measure
        XCTAssertEqual(Array(ids(RibbonLayout.visibleTabs(c, registry: registry)).suffix(2)), [.tableTools, .measureTools])
        // Model view: Table tools only once something is selected.
        c = RibbonContext(view: .model, modelHasTables: true)
        XCTAssertFalse(ids(RibbonLayout.visibleTabs(c, registry: registry)).contains(.tableTools))
        c.modelObject = .table
        XCTAssertTrue(ids(RibbonLayout.visibleTabs(c, registry: registry)).contains(.tableTools))
        // An empty model has no table to give tools for.
        XCTAssertFalse(ids(RibbonLayout.visibleTabs(RibbonContext(view: .table), registry: registry)).contains(.tableTools))
        // The DAX query tab belongs to its view.
        XCTAssertTrue(ids(RibbonLayout.visibleTabs(RibbonContext(view: .dax), registry: registry)).contains(.daxQuery))
        XCTAssertFalse(ids(RibbonLayout.visibleTabs(RibbonContext(view: .report), registry: registry)).contains(.daxQuery))
    }

    func testTabWithNothingRegisteredIsHiddenUntilACommandArrives() {
        let c = RibbonContext(view: .tmdl)
        XCTAssertFalse(ids(RibbonLayout.visibleTabs(c, registry: [])).contains(.tmdl))
        let tabs = RibbonLayout.visibleTabs(c, registry: [info("tmdl.apply", title: "Apply")])
        let tmdl = tabs.first { $0.id == .tmdl }
        XCTAssertEqual(tmdl?.groups.first?.items.map(\.control),
                       [.button(RibbonCommand(id: "tmdl.apply", label: "Apply", symbol: RibbonLayout.fallbackSymbol))])
    }

    func testActiveTabFallsBackToHome() {
        let tabs = RibbonLayout.visibleTabs(RibbonContext(view: .report), registry: RibbonRegistry.infos)
        XCTAssertEqual(RibbonLayout.activeTab(selected: .view, visible: tabs)?.id, .view)
        XCTAssertEqual(RibbonLayout.activeTab(selected: .format, visible: tabs)?.id, .home)
        XCTAssertNil(RibbonLayout.activeTab(selected: .home, visible: []))
    }

    func testColumnsStackSmallItemsThreeHigh() {
        func item(_ id: String, _ size: RibbonItem.Size) -> RibbonItem {
            RibbonItem(control: .button(RibbonCommand(id: id, label: id, symbol: "")), size: size)
        }
        let group = RibbonGroup(title: "G", items: [
            item("a", .large), item("b", .small), item("c", .small), item("d", .small), item("e", .small), item("f", .large), item("g", .small),
        ])
        XCTAssertEqual(RibbonLayout.columns(group), [
            .large(item("a", .large)),
            .stack([item("b", .small), item("c", .small), item("d", .small)]),
            .stack([item("e", .small)]),
            .large(item("f", .large)),
            .stack([item("g", .small)]),
        ])
        XCTAssertEqual(RibbonLayout.columns(RibbonGroup(title: "G", items: [])), [])
    }

    func testOverflowListsOnlyWhatTheRibbonDoesNotPlace() {
        let registry = [
            info("model.newMeasure"), info("model.somethingNew", title: "Something New"), info("model.somethingNew"),
            info("insert.visual.pie", .insert), info("model.table.rename"), info("other.thing", .view),
        ]
        XCTAssertEqual(RibbonLayout.overflow(menus: [.modeling, .insert], registry: registry).map(\.id), ["model.somethingNew"])
        // The "More" group disappears when it would be empty.
        let more = RibbonGroup(title: "More", items: [RibbonItem(control: .overflow(label: "More", menus: [.modeling]), size: .large)])
        XCTAssertTrue(RibbonLayout.expand(more, registry: [info("model.newMeasure")]).items.isEmpty)
        let expanded = RibbonLayout.expand(more, registry: registry)
        XCTAssertEqual(expanded.items.count, 1)
        if case .menu(_, _, let entries)? = expanded.items.first?.control {
            XCTAssertEqual(entries, [.command(RibbonCommand(id: "model.somethingNew", label: "Something New", symbol: ""))])
        } else { XCTFail("overflow should expand to a menu") }
    }

    func testFileMenuFollowsTheRegistry() {
        let entries = RibbonLayout.fileMenu(registry: [
            info("file.open", .file, title: "Open…"), info("x", .view), info("file.save", .file, title: "Save", separator: true),
        ])
        XCTAssertEqual(entries, [
            .command(RibbonCommand(id: "file.open", label: "Open…", symbol: "")), .divider,
            .command(RibbonCommand(id: "file.save", label: "Save", symbol: "")),
        ])
        XCTAssertFalse(RibbonLayout.fileMenu(registry: RibbonRegistry.infos).isEmpty)
    }

    /// The audit: which ribbon ids the real registry lacks. Printed so it can be read off a test run.
    func testOnlyKnownPendingCommandsAreUnregistered() {
        let registered = Set(AppCommands.all.map(\.id))
        let missing = RibbonLayout.unregisteredIDs(in: registered)
        print("Ribbon ids not registered: \(missing.joined(separator: ", "))")
        XCTAssertEqual(Set(missing).subtracting(Self.pending), [], "the ribbon names commands nobody registers")
        XCTAssertEqual(RibbonLayout.unregisteredIDs(in: Set(RibbonLayout.referencedIDs)), [])
    }

    /// Whatever a feature registers must be reachable from the ribbon: placed, in a gallery, in a
    /// "More" menu of some tab, or in the File menu.
    func testEveryRegisteredCommandIsReachableFromTheRibbon() {
        let registry = RibbonRegistry.infos
        var overflowMenus = Set<AppCommand.Menu>([.file])
        for tab in RibbonLayout.tabs where !tab.contextual {
            for group in tab.groups { for item in group.items {
                if case .overflow(_, let menus) = item.control { overflowMenus.formUnion(menus) }
            } }
        }
        let unreachable = registry.filter { !RibbonLayout.placesDirectly($0.id) && !overflowMenus.contains($0.menu) }
        XCTAssertEqual(unreachable.map(\.id), [])
        XCTAssertEqual(Set(AppCommand.Menu.allCases).subtracting(overflowMenus).subtracting([.format]), [],
                       "a command menu has no home on an always-visible tab")
    }

    func testEverySymbolExists() {
        var symbols = Set<String>([RibbonLayout.fallbackSymbol, "ellipsis.circle"])
        for tab in RibbonLayout.tabs { for group in tab.groups { for item in group.items {
            switch item.control {
            case .button(let c): symbols.insert(c.symbol)
            case .menu(_, let symbol, let entries):
                symbols.insert(symbol)
                for case .command(let c) in entries { symbols.insert(c.symbol) }
            case .visualGallery(_, let symbol): symbols.insert(symbol)
            case .registered, .overflow: break
            }
        } } }
        symbols.formUnion(WorkspaceView.allCases.map(\.symbol))
        symbols.formUnion(InspectorPane.allCases.map(\.symbol))
        symbols.formUnion(["chevron.right.2", "chevron.left.2", "sidebar.right", "hammer", "pause.circle", "person.crop.rectangle"])
        for symbol in symbols.sorted() {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "“\(symbol)” is not an SF Symbol")
        }
    }

    func testTooltips() {
        let ref = RibbonCommand(id: "file.save", label: "Save", symbol: "")
        XCTAssertEqual(RibbonHelp.text(for: ref, command: AppCommands.command("file.save")), "Save (⌘S)")
        XCTAssertEqual(RibbonHelp.text(for: ref, command: nil), "Save — not available yet")
        XCTAssertEqual(ShortcutText.describe(KeyboardShortcut("z", modifiers: [.command, .shift])), "⇧⌘Z")
        XCTAssertEqual(ShortcutText.describe(KeyboardShortcut(.return, modifiers: [.command, .option])), "⌥⌘↩")
    }
}

// MARK: - Pane dock

final class PaneDockTests: XCTestCase {
    private let bookmarks = InspectorPane.bookmarks.rawValue
    private let selection = InspectorPane.selection.rawValue
    private let assistant = InspectorPane.assistant.rawValue

    func testWindowsOrderInReportView() {
        var dock = PaneDock()
        XCTAssertEqual(dock.slots(for: .report), [.filters, .visualizations, .data])
        dock.reveal(bookmarks)
        XCTAssertEqual(dock.slots(for: .report), [.filters, .extras, .visualizations, .data])
        XCTAssertEqual(dock.slots(for: .table), [.data])
        XCTAssertEqual(dock.slots(for: .model), [.data])
        XCTAssertEqual(dock.slots(for: .dax), [])
    }

    func testEveryInspectorPaneHasAColumnAndUnknownPanesShareExtras() {
        XCTAssertEqual(PaneDock.slot(for: InspectorPane.filters.rawValue), .filters)
        XCTAssertEqual(PaneDock.slot(for: InspectorPane.build.rawValue), .visualizations)
        XCTAssertEqual(PaneDock.slot(for: InspectorPane.format.rawValue), .visualizations)
        XCTAssertEqual(PaneDock.slot(for: InspectorPane.data.rawValue), .data)
        for pane in [InspectorPane.bookmarks, .selection, .syncSlicers, .performance, .theme, .assistant] {
            XCTAssertEqual(PaneDock.slot(for: pane.rawValue), .extras)
        }
        XCTAssertEqual(PaneDock.slot(for: "properties"), .extras)   // a pane added by a later feature
    }

    func testRevealCloseAndToggle() {
        var dock = PaneDock()
        func showing(_ pane: InspectorPane, _ view: WorkspaceView = .report, _ width: Double = 1400) -> Bool {
            dock.isShowing(pane.rawValue, view: view, available: width)
        }
        XCTAssertTrue(showing(.build))
        XCTAssertFalse(showing(.format))
        dock.reveal(InspectorPane.format.rawValue)
        XCTAssertEqual(dock.pane(in: .visualizations, view: .report), InspectorPane.format.rawValue)
        XCTAssertFalse(showing(.build))

        dock.close(InspectorPane.filters.rawValue)
        XCTAssertEqual(dock.slots(for: .report), [.visualizations, .data])
        XCTAssertFalse(showing(.filters))
        dock.reveal(InspectorPane.filters.rawValue)
        XCTAssertEqual(dock.slots(for: .report), [.filters, .visualizations, .data])

        // A collapsed pane is not "showing"; revealing it expands it.
        dock.setCollapsed(.data, true)
        XCTAssertFalse(showing(.data))
        dock.reveal(InspectorPane.data.rawValue)
        XCTAssertTrue(showing(.data))
    }

    func testShowingMeansDrawnExpandedInThisViewAtThisWidth() {
        var dock = PaneDock()
        let filters = InspectorPane.filters.rawValue, build = InspectorPane.build.rawValue, data = InspectorPane.data.rawValue
        // Wide window: all three are drawn.
        XCTAssertTrue(dock.isShowing(filters, view: .report, available: 1400))
        // Narrow window: Filters is an automatic strip, so it is not showing — although nothing hid it.
        XCTAssertFalse(dock.isShowing(filters, view: .report, available: 952))
        XCTAssertTrue(dock.isShowing(build, view: .report, available: 952))
        // Asking for it expands it; another pane gives way instead.
        dock.reveal(filters)
        XCTAssertTrue(dock.isShowing(filters, view: .report, available: 952))
        XCTAssertFalse(dock.isShowing(data, view: .report, available: 952))
        // Table view has no Filters or Visualizations column, whatever the dock remembers.
        XCTAssertFalse(dock.isShowing(filters, view: .table, available: 1400))
        XCTAssertFalse(dock.isShowing(build, view: .table, available: 1400))
        XCTAssertTrue(dock.isShowing(data, view: .table, available: 1400))
        dock.reveal(bookmarks)
        XCTAssertTrue(dock.isShowing(bookmarks, view: .report, available: 1600))
        XCTAssertFalse(dock.isShowing(bookmarks, view: .table, available: 1600))
    }

    func testPaneAvailabilityByView() {
        for pane in InspectorPane.allCases { XCTAssertTrue(PaneDock.isAvailable(pane.rawValue, in: .report), "\(pane)") }
        XCTAssertTrue(PaneDock.isAvailable(InspectorPane.data.rawValue, in: .table))
        XCTAssertTrue(PaneDock.isAvailable(assistant, in: .dax))
        XCTAssertTrue(PaneDock.isAvailable("properties", in: .model))      // a pane from a later feature
        for pane in [InspectorPane.filters, .build, .format, .bookmarks, .selection, .syncSlicers, .performance, .theme] {
            XCTAssertFalse(PaneDock.isAvailable(pane.rawValue, in: .table), "\(pane)")
        }
        XCTAssertFalse(PaneDock.isAvailable(InspectorPane.data.rawValue, in: .tmdl))
    }

    func testResizeIsClampedToTheCanvasBudget() {
        var dock = PaneDock()
        dock.bringForward(.data)               // what a drag does first
        // 1400 wide: Filters 260 + Visualizations 300 + canvas 340 leave 500 for Data.
        XCTAssertEqual(dock.maximumWidth(of: .data, view: .report, available: 1400), 500)
        dock.setWidth(5000, of: .data, view: .report, available: 1400)
        XCTAssertEqual(dock.width(of: .data), 500)
        // Dragging as far as it goes collapses nothing — least of all the pane being dragged.
        XCTAssertFalse(dock.columns(for: .report, available: 1400).contains { $0.collapsed })
        // The budget never drops below the minimum pane width, and NaN is ignored.
        XCTAssertEqual(dock.maximumWidth(of: .data, view: .report, available: 400), PaneDock.widthRange.lowerBound)
        dock.setWidth(.nan, of: .data, view: .report, available: 1400)
        XCTAssertEqual(dock.width(of: .data), 500)
        // Width-only differences are not a change of arrangement (they are saved when the drag ends).
        var other = dock
        other.setWidth(300, of: .data)
        XCTAssertTrue(dock.sameArrangement(as: other))
        other.setCollapsed(.data, true)
        XCTAssertFalse(dock.sameArrangement(as: other))
    }

    func testExtraPanesShareOneColumn() {
        var dock = PaneDock()
        dock.reveal(bookmarks)
        dock.reveal(selection)
        XCTAssertEqual(dock.extras(for: .report), [bookmarks, selection])
        XCTAssertEqual(dock.activeExtra(for: .report), selection)
        XCTAssertFalse(dock.isShowing(bookmarks, view: .report, available: 1600))
        dock.reveal(bookmarks)                 // behind another pane: bring it forward
        XCTAssertEqual(dock.activeExtra(for: .report), bookmarks)
        XCTAssertTrue(dock.isShowing(bookmarks, view: .report, available: 1600))
        dock.close(bookmarks)
        XCTAssertEqual(dock.extras(for: .report), [selection])
        XCTAssertEqual(dock.activeExtra(for: .report), selection)
        dock.close(selection)
        XCTAssertNil(dock.activeExtra(for: .report))
        XCTAssertFalse(dock.slots(for: .report).contains(.extras))
    }

    func testReportOnlyPanesStayOutOfOtherViews() {
        var dock = PaneDock()
        dock.reveal(assistant)
        dock.reveal(bookmarks)
        XCTAssertEqual(dock.activeExtra(for: .report), bookmarks)
        XCTAssertEqual(dock.extras(for: .dax), [assistant])
        XCTAssertEqual(dock.activeExtra(for: .dax), assistant)
        XCTAssertEqual(dock.slots(for: .dax), [.extras])
        XCTAssertEqual(dock.slots(for: .table), [.extras, .data])
        dock.close(assistant)
        XCTAssertEqual(dock.slots(for: .tmdl), [])
    }

    func testWideWindowKeepsEveryPaneOpen() {
        let columns = PaneDock().columns(for: .report, available: 1392)
        XCTAssertEqual(columns.map(\.slot), [.filters, .visualizations, .data])
        XCTAssertEqual(columns.map(\.width), [260, 300, 270])
        XCTAssertFalse(columns.contains { $0.collapsed })
    }

    func testNarrowWindowCollapsesPanesToKeepTheCanvas() {
        var dock = PaneDock()
        // 1000-pt window less the rail: Filters gives way first, then Data; Visualizations last.
        var columns = dock.columns(for: .report, available: 952)
        XCTAssertEqual(columns.map(\.collapsed), [true, false, false])
        XCTAssertEqual(columns.first?.automatic, true)
        XCTAssertGreaterThanOrEqual(952 - columns.reduce(0) { $0 + $1.width }, 0)
        columns = dock.columns(for: .report, available: 800)
        XCTAssertEqual(columns.map(\.collapsed), [true, false, true])
        columns = dock.columns(for: .report, available: 300)
        XCTAssertEqual(columns.map(\.collapsed), [true, true, true])
        XCTAssertEqual(columns.map(\.width), [30, 30, 30])
        // Nothing the layout did is written into the user's choices.
        XCTAssertTrue(dock.collapsed.isEmpty)

        // Expanding an automatically collapsed pane makes it the last to give way.
        dock.setCollapsed(.filters, false)
        columns = dock.columns(for: .report, available: 952)
        XCTAssertEqual(columns.map(\.collapsed), [false, false, true])
    }

    func testUserCollapsedColumnsAreStrips() {
        var dock = PaneDock()
        dock.setCollapsed(.visualizations, true)
        let columns = dock.columns(for: .report, available: 1400)
        XCTAssertEqual(columns.map(\.width), [260, 30, 270])
        XCTAssertEqual(columns.map(\.automatic), [false, false, false])
        dock.reveal(InspectorPane.format.rawValue)   // opening a pane in a collapsed column expands it
        XCTAssertFalse(dock.collapsed.contains(.visualizations))
    }

    func testWidthsAreClamped() {
        var dock = PaneDock()
        dock.setWidth(10, of: .data)
        XCTAssertEqual(dock.width(of: .data), PaneDock.widthRange.lowerBound)
        dock.setWidth(5000, of: .data)
        XCTAssertEqual(dock.width(of: .data), PaneDock.widthRange.upperBound)
        dock.setWidth(.nan, of: .data)
        XCTAssertEqual(dock.width(of: .data), PaneDock.widthRange.upperBound)
        dock.widths["filters"] = -4          // a damaged preference
        XCTAssertEqual(dock.width(of: .filters), PaneDock.widthRange.lowerBound)
    }

    func testPreferencesRoundTripAndSurviveDamage() throws {
        var dock = PaneDock()
        dock.reveal(bookmarks); dock.reveal(InspectorPane.format.rawValue)
        dock.setCollapsed(.filters, true); dock.close(InspectorPane.data.rawValue); dock.setWidth(333, of: .extras)
        let copy = try JSONDecoder().decode(PaneDock.self, from: JSONEncoder().encode(dock))
        XCTAssertEqual(copy, dock)

        let damaged = #"{"hidden":["nonsense","data"],"visualizationsPane":"bookmarks","openExtras":["filters","selection"],"widths":"wide"}"#
        let recovered = try JSONDecoder().decode(PaneDock.self, from: Data(damaged.utf8))
        XCTAssertEqual(recovered.hidden, [.data])
        XCTAssertEqual(recovered.visualizationsPane, InspectorPane.build.rawValue)
        XCTAssertEqual(recovered.openExtras, [selection])
        XCTAssertEqual(recovered.width(of: .filters), DockSlot.filters.defaultWidth)
    }
}

// MARK: - Shell state and its commands

@MainActor
final class ShellStateTests: XCTestCase {
    private var suite = ""

    override func setUp() {
        super.setUp()
        Features.registerAll()
        suite = "shell-tests-\(UUID().uuidString)"
        ShellState.preferences = UserDefaults(suiteName: suite) ?? .standard
    }
    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        ShellState.preferences = .standard
        super.tearDown()
    }

    func testFeaturesOpenPanesThroughTheStore() {
        let store = DocumentStore(services: .live())
        let shell = ShellState.of(store)
        XCTAssertTrue(shell === ShellState.of(store))
        XCTAssertFalse(shell.isShowing(.bookmarks))
        store.inspector = .bookmarks            // how features ask for a pane
        XCTAssertTrue(shell.isShowing(.bookmarks))
        shell.dock.setCollapsed(.extras, true)
        store.inspector = .bookmarks            // asking again, same value, brings it back
        XCTAssertTrue(shell.isShowing(.bookmarks))
    }

    func testPaneCommandsToggleTheDock() {
        let store = DocumentStore(services: .live())
        let shell = ShellState.of(store)
        XCTAssertEqual(AppCommands.command("view.pane.filters")?.isOn?(store), true)
        AppCommands.run("view.pane.filters", store)
        XCTAssertFalse(shell.dock.slots(for: .report).contains(.filters))
        XCTAssertEqual(AppCommands.command("view.pane.filters")?.isOn?(store), false)
        AppCommands.run("view.pane.selection", store)
        XCTAssertEqual(shell.dock.activeExtra(for: .report), InspectorPane.selection.rawValue)
        // Hiding all panes turns every switch off; asking for one shows the dock again.
        store.inspectorVisible = false
        XCTAssertEqual(AppCommands.command("view.pane.selection")?.isOn?(store), false)
        AppCommands.run("view.pane.selection", store)
        XCTAssertTrue(store.inspectorVisible)
        XCTAssertTrue(shell.isShowing(.selection))
        AppCommands.run("optimize.performance", store)
        XCTAssertTrue(shell.isShowing(.performance))
    }

    func testRibbonCollapseAndPeek() {
        let store = DocumentStore(services: .live())
        let shell = ShellState.of(store)
        XCTAssertFalse(shell.ribbonCollapsed)
        shell.choose(.insert)
        XCTAssertFalse(shell.ribbonPeeking)     // expanded: nothing to peek at
        AppCommands.run("view.ribbon", store)
        XCTAssertTrue(shell.ribbonCollapsed)
        XCTAssertEqual(AppCommands.command("view.ribbon")?.isOn?(store), true)
        shell.choose(.view)
        XCTAssertTrue(shell.ribbonPeeking)
        XCTAssertEqual(shell.ribbonTab, .view)
        shell.choose(.home)                     // another tab: stay open, switch
        XCTAssertTrue(shell.ribbonPeeking)
        shell.run("view.gridlines")             // running a command puts it away
        XCTAssertFalse(shell.ribbonPeeking)
        XCTAssertTrue(store.showGridlines)
        shell.choose(.home); shell.choose(.home)   // same tab twice: open, then closed
        XCTAssertFalse(shell.ribbonPeeking)
        // The preference is remembered for the next document.
        XCTAssertTrue(ShellState.of(DocumentStore(services: .live())).ribbonCollapsed)
    }

    func testDrillCommandsNeedADataVisual() {
        let store = DocumentStore(services: .live())
        XCTAssertEqual(AppCommands.command("drill.showAsTable")?.isEnabled(store), false)
        let text = store.addVisual(.textBox)
        store.selection = [text]
        XCTAssertEqual(AppCommands.command("drill.showAsTable")?.isEnabled(store), false)
        XCTAssertEqual(RibbonContext.current(store).dataVisualSelected, false)
        let chart = store.addVisual(.clusteredColumn)
        store.selection = [chart]
        XCTAssertEqual(RibbonContext.current(store).dataVisualSelected, true)
        XCTAssertEqual(AppCommands.command("drill.up")?.isEnabled(store), false)   // already at the top level
        AppCommands.run("drill.showAsTable", store)
        XCTAssertEqual(store.showAsTableID, chart)
    }

    func testSlicerButtonCommandAddsAWorkingButton() {
        let store = DocumentStore(services: .live())
        AppCommands.run("optimize.applyAllSlicers", store)
        let button = store.currentPage.visuals.last
        XCTAssertEqual(button?.type, .button)
        XCTAssertEqual(button?.action?.kind, .applyAllSlicers)
        XCTAssertNotNil(store.undoName, "adding the button must be an undoable document change")
        store.undo()
        XCTAssertFalse(store.currentPage.visuals.contains { $0.type == .button })
    }

    // MARK: Review findings

    /// 2: under about 1218 pt Filters is an automatic strip. Its switch must be off, and choosing it
    /// must expand the pane, not close it.
    func testPaneSwitchInANarrowWindowExpandsTheStrip() {
        let store = DocumentStore(services: .live())
        let shell = ShellState.of(store)
        shell.available = 952
        let filters = AppCommands.command("view.pane.filters")
        XCTAssertEqual(filters?.isOn?(store), false)
        AppCommands.run("view.pane.filters", store)
        XCTAssertFalse(shell.dock.hidden.contains(.filters), "the switch closed a pane that was only a strip")
        XCTAssertEqual(filters?.isOn?(store), true)
        XCTAssertEqual(shell.dock.columns(for: .report, available: 952).map(\.collapsed), [false, false, true])
        AppCommands.run("view.pane.filters", store)          // now it is showing: the switch closes it
        XCTAssertTrue(shell.dock.hidden.contains(.filters))
        // A strip the user collapsed behaves the same way.
        shell.available = 1600
        shell.dock.setCollapsed(.data, true)
        XCTAssertEqual(AppCommands.command("view.pane.data")?.isOn?(store), false)
        AppCommands.run("view.pane.data", store)
        XCTAssertEqual(AppCommands.command("view.pane.data")?.isOn?(store), true)
    }

    /// 2: switches for panes the current view cannot show are disabled and do nothing.
    func testPaneSwitchesAreDisabledWhereThePaneCannotShow() {
        let store = DocumentStore(services: .live())
        let shell = ShellState.of(store)
        store.view = .table
        for id in ["view.pane.build", "view.pane.format", "view.pane.filters", "view.pane.bookmarks"] {
            XCTAssertEqual(AppCommands.command(id)?.isEnabled(store), false, id)
            XCTAssertEqual(AppCommands.command(id)?.isOn?(store), false, id)
        }
        let before = shell.dock
        AppCommands.run("view.pane.bookmarks", store)
        shell.toggle(.format)
        XCTAssertEqual(shell.dock, before)
        XCTAssertEqual(AppCommands.command("view.pane.data")?.isEnabled(store), true)
        XCTAssertEqual(AppCommands.command("view.pane.data")?.isOn?(store), true)
        XCTAssertEqual(AppCommands.command("view.pane.assistant")?.isEnabled(store), true)
        // Nothing is showing while presenting.
        store.view = .report
        store.presenting = true
        XCTAssertFalse(shell.isShowing(.data))
    }

    /// 12: `store.inspector` is the pane most recently brought forward, however that happened.
    func testStoreInspectorFollowsThePaneOnShow() {
        let store = DocumentStore(services: .live())
        let shell = ShellState.of(store)
        shell.show(.format)
        XCTAssertEqual(store.inspector, .format)
        XCTAssertTrue(shell.isShowing(.format))
        AppCommands.run("view.pane.selection", store)
        XCTAssertEqual(store.inspector, .selection)
        store.inspector = .data
        XCTAssertTrue(shell.isShowing(.data))
        shell.dock.setCollapsed(.data, true)
        shell.show(.data)                       // already the current pane: still brought forward
        XCTAssertTrue(shell.isShowing(.data))
    }

    /// 3 and 8: a drag marks its pane first, publishes and saves nothing per tick, and saves once at the end.
    func testResizeDragSavesOnceAndDoesNotPublishThroughTheStore() throws {
        let store = DocumentStore(services: .live())
        let shell = ShellState.of(store)
        shell.available = 1400
        func savedWidth() -> Double? {
            ShellState.preferences.data(forKey: "shell.paneDock")
                .flatMap { try? JSONDecoder().decode(PaneDock.self, from: $0) }?.widths[DockSlot.data.rawValue]
        }
        shell.beginResize(.data)
        XCTAssertEqual(shell.dock.recency.last, .data)
        var published = 0
        let observation = store.objectWillChange.sink { published += 1 }
        defer { observation.cancel() }
        for width in [300.0, 380, 460, 5000] { shell.resize(.data, to: width) }
        XCTAssertEqual(published, 0, "a width change went through the store's publisher")
        XCTAssertNil(savedWidth(), "a width was saved in the middle of a drag")
        XCTAssertEqual(shell.dock.width(of: .data), 500)        // clamped to the canvas budget
        XCTAssertFalse(shell.dock.columns(for: .report, available: 1400).contains { $0.collapsed })
        shell.endResize()
        XCTAssertEqual(savedWidth(), 500)
    }

    func testResizeCursorStaysBalanced() {
        var depth = 0
        let cursor = ResizeCursor(push: { depth += 1 }, pop: { depth -= 1 })
        cursor.set(true); cursor.set(true)      // hover reported twice
        XCTAssertEqual(depth, 1)
        cursor.set(false)                       // the handle disappears while hovered
        cursor.set(false)                       // …and a late hover-out arrives
        XCTAssertEqual(depth, 0)
        cursor.set(true); cursor.set(false)
        XCTAssertEqual(depth, 0)
    }

    /// 11: a command run from anywhere puts a peeking ribbon away.
    func testAnyCommandRunPutsThePeekAway() throws {
        let store = DocumentStore(services: .live())
        let shell = ShellState.of(store)
        shell.ribbonCollapsed = true
        shell.choose(.view)
        XCTAssertTrue(shell.ribbonPeeking)
        AppCommands.run("view.gridlines", store)                 // toolbar, rail, panes
        XCTAssertFalse(shell.ribbonPeeking)
        shell.choose(.view)
        AppCommands.perform(try XCTUnwrap(AppCommands.command("view.snap")), store)   // menu bar, shortcut, palette
        XCTAssertFalse(shell.ribbonPeeking)
        // A disabled command does not run and so changes nothing.
        shell.choose(.view)
        AppCommands.run("edit.delete", store)
        XCTAssertTrue(shell.ribbonPeeking)
    }

    /// 1: document-scoped notifications carry their store, and a window answers only its own.
    func testDocumentNotificationsAreAddressedToTheirStore() {
        let store = DocumentStore(services: .live())
        let other = DocumentStore(services: .live())
        for (command, name) in [("data.transform", Notification.Name.facetOpenQueryEditor), ("view.palette", .facetShowPalette)] {
            var received: Notification?
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { received = $0 }
            AppCommands.run(command, store)
            NotificationCenter.default.removeObserver(token)
            guard let note = received else { XCTFail("\(command) posted nothing"); continue }
            XCTAssertTrue(ShellNotifications.isAddressed(note, to: store), "\(command) is not addressed to its document")
            XCTAssertFalse(ShellNotifications.isAddressed(note, to: other))
        }
        XCTAssertFalse(ShellNotifications.isAddressed(Notification(name: .facetOpenQueryEditor, object: nil), to: store))
        // A data-function button says why nothing happened, by name.
        var action = ActionSpec()
        action.kind = .dataFunction
        action.functionName = "ApproveOrder"
        var note: Notification?
        let token = NotificationCenter.default.addObserver(forName: .facetRunDataFunction, object: nil, queue: nil) { note = $0 }
        store.perform(action)
        NotificationCenter.default.removeObserver(token)
        XCTAssertTrue(note.map { ShellNotifications.isAddressed($0, to: store) } ?? false)
        XCTAssertTrue(note.map(ShellNotifications.dataFunctionMessage)?.contains("“ApproveOrder”") ?? false)
    }

    /// 9: the ribbon is resolved against the registry once per generation, not per render.
    func testRibbonIsResolvedOncePerRegistryGeneration() {
        let store = DocumentStore(services: .live())
        _ = RibbonRegistry.visibleTabs(store)
        let resolutions = RibbonRegistry.resolutions
        for view in WorkspaceView.allCases {
            store.view = view
            XCTAssertFalse(RibbonRegistry.visibleTabs(store).isEmpty)
            _ = RibbonRegistry.fileMenu
        }
        XCTAssertEqual(RibbonRegistry.resolutions, resolutions)
        XCTAssertEqual(RibbonRegistry.visibleTabs(store), RibbonLayout.visibleTabs(.current(store), registry: RibbonRegistry.infos))
        AppCommands.invalidate()
        _ = RibbonRegistry.visibleTabs(store)
        XCTAssertEqual(RibbonRegistry.resolutions, resolutions + 1)
    }

    /// 10: Optimize ▸ slicers inserts the two buttons; the immediate clear is apart and says "now".
    func testOptimizeSlicerGroupInsertsButtons() throws {
        let optimize = try XCTUnwrap(RibbonLayout.tabs.first { $0.id == .optimize })
        let group = try XCTUnwrap(optimize.groups.first { $0.title == "Insert slicer buttons" })
        let commands = group.items.compactMap { item -> RibbonCommand? in
            if case .button(let c) = item.control { return c } else { return nil }
        }
        XCTAssertEqual(commands.map(\.id), ["optimize.applyAllSlicers", "optimize.clearAllSlicersButton"])
        XCTAssertTrue(commands.allSatisfy { $0.label.hasSuffix("button") })
        for id in commands.map(\.id) {
            XCTAssertTrue(AppCommands.command(id)?.title.hasSuffix("Button") ?? false, id)
        }
        XCTAssertEqual(AppCommands.command("optimize.clearSlicers")?.title, "Clear Slicer Selections Now")
        let store = DocumentStore(services: .live())
        AppCommands.run("optimize.clearAllSlicersButton", store)
        XCTAssertEqual(store.currentPage.visuals.last?.action?.kind, .clearAllSlicers)
    }

    func testAppNameComesFromOneConstant() {
        XCTAssertEqual(AppIdentity.name, "Analytics Desktop")
        XCTAssertEqual(AppCommands.command("help.about")?.title, "About Analytics Desktop")
        XCTAssertEqual(ExternalTools.folder?.pathComponents.suffix(2), ["Analytics Desktop", "External Tools"])
    }
}

// MARK: - Status bar, page tabs, external tools

final class ShellModelTests: XCTestCase {
    func testPageLabel() {
        XCTAssertEqual(StatusModel.pageLabel(index: 1, count: 5), "Page 2 of 5")
        XCTAssertEqual(StatusModel.pageLabel(index: 0, count: 1), "Page 1 of 1")
        XCTAssertEqual(StatusModel.pageLabel(index: nil, count: 3), "3 pages")
        XCTAssertEqual(StatusModel.pageLabel(index: 7, count: 3), "3 pages")
        XCTAssertEqual(StatusModel.pageLabel(index: 0, count: 0), "No pages")
    }

    func testStorageLabel() {
        XCTAssertNil(StatusModel.storageLabel([]))
        XCTAssertEqual(StatusModel.storageLabel([.import, .import]), "Import")
        XCTAssertEqual(StatusModel.storageLabel([.directQuery]), "DirectQuery")
        XCTAssertEqual(StatusModel.storageLabel([.import, .directQuery, .dual]), "Mixed")
    }

    func testZoomSlider() {
        XCTAssertEqual(StatusModel.sliderPosition(zoom: 0.1), 0, accuracy: 1e-9)
        XCTAssertEqual(StatusModel.sliderPosition(zoom: 4), 1, accuracy: 1e-9)
        XCTAssertEqual(StatusModel.sliderPosition(zoom: 99), 1, accuracy: 1e-9)
        XCTAssertEqual(StatusModel.sliderPosition(zoom: .nan), StatusModel.sliderPosition(zoom: 1), accuracy: 1e-9)
        XCTAssertEqual(StatusModel.zoom(sliderPosition: 0), 0.1, accuracy: 1e-9)
        XCTAssertEqual(StatusModel.zoom(sliderPosition: 1), 4, accuracy: 1e-9)
        XCTAssertEqual(StatusModel.zoom(sliderPosition: -3), 0.1, accuracy: 1e-9)
        XCTAssertEqual(StatusModel.zoom(sliderPosition: StatusModel.sliderPosition(zoom: 1.02)), 1)   // snaps to 100%
        for z in [0.25, 0.5, 0.75, 1.5, 2, 3] {
            XCTAssertEqual(StatusModel.zoom(sliderPosition: StatusModel.sliderPosition(zoom: z)), z, accuracy: 0.011)
        }
        XCTAssertEqual(StatusModel.percent(0.666), "67%")
    }

    func testPageTabRules() {
        let id = UUID()
        XCTAssertEqual(PageTabsModel.draggedPage(PageTabsModel.dragPayload(for: id)), id)
        XCTAssertNil(PageTabsModel.draggedPage(id.uuidString))
        XCTAssertNil(PageTabsModel.draggedPage("facet-page:not-a-uuid"))
        XCTAssertEqual(PageTabsModel.destination(from: 0, onto: 2, count: 3), 2)
        XCTAssertEqual(PageTabsModel.destination(from: 2, onto: 0, count: 3), 0)
        XCTAssertNil(PageTabsModel.destination(from: 1, onto: 1, count: 3))
        XCTAssertNil(PageTabsModel.destination(from: 3, onto: 0, count: 3))
        XCTAssertNil(PageTabsModel.destination(from: 0, onto: -1, count: 3))
        XCTAssertEqual(PageTabsModel.committedName("  Sales  ", current: "Page 1"), "Sales")
        XCTAssertNil(PageTabsModel.committedName("   ", current: "Page 1"))
        XCTAssertNil(PageTabsModel.committedName("Page 1", current: "Page 1"))
        XCTAssertFalse(PageTabsModel.canDelete(pageCount: 1))
        XCTAssertTrue(PageTabsModel.canDelete(pageCount: 2))
    }

    @MainActor
    func testPageReorderThroughTheStoreIsUndoable() {
        let store = DocumentStore(services: .live())
        store.addPage(named: "B"); store.addPage(named: "C")
        let names = { store.report.pages.map(\.name) }
        let before = names()
        guard let to = PageTabsModel.destination(from: 0, onto: 2, count: store.report.pages.count) else { return XCTFail() }
        store.movePage(from: 0, to: to)
        XCTAssertEqual(names(), [before[1], before[2], before[0]])
        store.undo()
        XCTAssertEqual(names(), before)
    }

    func testExternalToolRegistration() {
        let json = #"{"version":"1.0","name":"DAX Studio","description":"Query tool","path":"/Applications/DAX Studio.app","arguments":"\"%file%\" -s \"%server%\""}"#
        let tool = ExternalTool.decode(Data(json.utf8))
        XCTAssertEqual(tool?.name, "DAX Studio")
        XCTAssertEqual(tool?.description, "Query tool")
        XCTAssertEqual(tool?.slug, "dax-studio")
        XCTAssertNil(ExternalTool.decode(Data(#"{"name":"  ","path":"/x"}"#.utf8)))
        XCTAssertNil(ExternalTool.decode(Data(#"{"name":"X"}"#.utf8)))
        XCTAssertNil(ExternalTool.decode(Data("not json".utf8)))
        XCTAssertEqual(ExternalTool.split(""), [])
        XCTAssertEqual(ExternalTool.split("  a   \"b c\"  \"\" "), ["a", "b c", ""])
    }

    private func tool(_ arguments: String, name: String = "Tool") -> ExternalTool {
        ExternalTool(name: name, description: "", path: "/usr/bin/true", arguments: arguments)
    }

    /// 5: one pass over the template; what is substituted in is never scanned again, and every
    /// value stays one argv entry.
    func testExternalToolPlaceholdersAreFilledInOnePass() {
        let awkward = "/Users/me/50%database% \"final\" %file%/My Report.facet"
        XCTAssertEqual(tool("\"%file%\" --in=%FILE% plain").argv(file: awkward), [awkward, "--in=" + awkward, "plain"])
        XCTAssertEqual(ExternalTool.substitute("%file%%file%", values: [.file: "%file%"]), "%file%%file%")
        XCTAssertEqual(ExternalTool.substitute("100% %filex% %", values: [.file: "F"]), "100% %filex% %")
        XCTAssertEqual(ExternalTool.placeholders(in: "-s %Server% \"%file%\""), [.server, .file])
        XCTAssertEqual(ExternalTool.placeholders(in: "--verbose"), [])
    }

    /// 4 and 6: what happens when a tool is chosen, from the document's saved state.
    func testExternalToolLaunchDecisions() {
        let saved = URL(fileURLWithPath: "/tmp/My Report.facet")
        // Needs the file: an untitled or edited document must be saved first — never an empty argument.
        XCTAssertEqual(tool("\"%file%\"").launch(file: nil, isDirty: false, isApplication: false), .saveFirst)
        XCTAssertEqual(tool("\"%file%\"").launch(file: saved, isDirty: true, isApplication: true), .saveFirst)
        XCTAssertEqual(tool("-o \"%file%\"").launch(file: saved, isDirty: false, isApplication: false),
                       .run(arguments: ["-o", "/tmp/My Report.facet"]))
        // An app given just the document is asked to open it, which works when it is already running.
        XCTAssertEqual(tool("\"%file%\"").launch(file: saved, isDirty: false, isApplication: true), .openDocument(saved))
        XCTAssertEqual(tool("--edit %file%").launch(file: saved, isDirty: false, isApplication: true),
                       .run(arguments: ["--edit", "/tmp/My Report.facet"]))
        // No placeholders: the document's state does not matter.
        XCTAssertEqual(tool("--new").launch(file: nil, isDirty: true, isApplication: false), .run(arguments: ["--new"]))
        XCTAssertEqual(tool("").launch(file: nil, isDirty: true, isApplication: true), .run(arguments: []))
        // There is no local engine endpoint: refuse, with the reason, rather than pass empty strings.
        for template in ["\"%server%\" \"%database%\"", "%file% -d %DATABASE%"] {
            guard case .refuse(let reason) = tool(template, name: "DAX Studio").launch(file: saved, isDirty: false, isApplication: false) else {
                XCTFail("\(template) should be refused"); continue
            }
            XCTAssertTrue(reason.contains("DAX Studio") && reason.contains("no local Analysis Services endpoint"), reason)
        }
    }

    /// 7: names that differ only in case or punctuation keep separate commands, and the
    /// description is the tooltip.
    func testExternalToolCommandIDsAreUniqueAndDescriptionsAreTooltips() {
        let tools = ["DAX Studio", "dax.studio", "Dax-Studio", "Bravo"].map { tool("", name: $0) }
        XCTAssertEqual(ExternalTool.commandIDs(for: tools), [
            "externalTools.tool.dax-studio", "externalTools.tool.dax-studio-2", "externalTools.tool.dax-studio-3", "externalTools.tool.bravo",
        ])
        XCTAssertEqual(ExternalTool.commandIDs(for: []), [])
        let ref = RibbonCommand(id: "x", label: "Bravo", symbol: "hammer")
        let command = AppCommand(id: "x", title: "Bravo", menu: .tools, help: "Optimise a model") { _ in }
        XCTAssertEqual(RibbonHelp.text(for: ref, command: command), "Bravo — Optimise a model")
    }
}
