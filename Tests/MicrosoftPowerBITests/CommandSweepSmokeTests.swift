import XCTest
import AppKit
import SwiftUI
import FacetCore
@testable import MicrosoftPowerBI

/// Every registered command, run as the ribbon, menu bar and palette run it (`AppCommands.perform`),
/// on an empty document and on the sample with a chart selected; and every workspace view, pane
/// and the whole window hosted offscreen on both.
///
/// Modal panels and alerts are answered Cancel by `ModalGuard`, so a command that asks for a file
/// cannot block the run; the commands that would leave the app (browser, Finder, other apps, the
/// system About panel) or change the user's Microsoft account are skipped and listed.
@MainActor
final class CommandSweepSmokeTests: XCTestCase {
    /// Commands not run, and why. Everything else is run.
    static let skipped: [String: String] = [
        "help.dax": "opens the DAX reference in the browser",
        "help.powerQuery": "opens the M reference in the browser",
        "help.about": "opens the system About panel",
        "externalTools.openFolder": "opens a folder in Finder",
        "account.signIn": "opens Microsoft sign-in in the browser once a client ID is set",
        "account.signOut": "removes the signed-in Microsoft accounts from the Keychain",
    ]
    static func isSkipped(_ id: String) -> Bool {
        skipped[id] != nil || id.hasPrefix("externalTools.tool.")   // external tools launch other apps
    }

    private var savedPasteboard: [[NSPasteboard.PasteboardType: Data]] = []

    override func setUp() async throws {
        try await super.setUp()
        Features.registerAll()
        ModalGuard.install()
        ModalGuard.opened = []
        // Copy and Cut write to the general pasteboard: keep what the user had there.
        savedPasteboard = NSPasteboard.general.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        } ?? []
    }

    override func tearDown() async throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(savedPasteboard.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        })
        try await super.tearDown()
    }

    /// What a command visibly did, for the list of commands that did nothing.
    private struct Effects: Equatable {
        var undo: String?, dirty: Bool, view: WorkspaceView, inspector: InspectorPane, inspectorVisible: Bool
        var zoom: Double, fit: Bool, toggles: [Bool], selection: Set<UUID>, page: UUID, status: UUID?, sheet: UUID?
        var focus: UUID?, table: UUID?, interactions: UUID?, painter: UUID?, ribbon: Bool, dock: String
        @MainActor init(_ s: DocumentStore) {
            undo = s.undoName; dirty = s.isDirty; view = s.view; inspector = s.inspector; inspectorVisible = s.inspectorVisible
            zoom = s.zoom; fit = s.fitToWindow
            toggles = [s.showGridlines, s.snapToGrid, s.lockObjects, s.mobileLayout, s.presenting, s.visualsPaused, s.performanceRecording]
            selection = s.selection; page = s.currentPageID; status = s.status?.id; sheet = s.sheet?.id
            focus = s.focusVisualID; table = s.showAsTableID; interactions = s.editInteractionsFor; painter = s.formatPainterSource
            let shell = ShellState.of(s)
            ribbon = shell.ribbonCollapsed
            dock = "\(shell.dock)"
        }
    }

    /// Runs every command on a fresh store made by `make`. Returns the ids that were enabled but
    /// showed no effect at all.
    private func sweep(_ label: String, make: () async -> DocumentStore) async -> Sweep {
        var ran: [String] = [], quiet: [String] = [], panels: [String] = [], errors: [String] = []
        let ids = AppCommands.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two commands share an id")
        for id in ids where !Self.isSkipped(id) {
            let store = await make()
            guard let command = AppCommands.command(id) else { XCTFail("\(id) vanished"); continue }
            guard command.isEnabled(store) else { continue }
            var notes = 0
            let observer = NotificationCenter.default.addObserver(forName: nil, object: store, queue: nil) { _ in notes += 1 }
            let asked = ModalGuard.opened.count
            let before = Effects(store)
            AppCommands.perform(command, store)
            await Smoke.settle(store)
            NotificationCenter.default.removeObserver(observer)
            ran.append(id)
            // Still a working document: a current page, a valid selection, a loaded engine.
            XCTAssertFalse(store.report.pages.isEmpty, "\(label) ▸ \(id) left no pages")
            XCTAssertTrue(store.report.pages.contains { $0.id == store.currentPageID }, "\(label) ▸ \(id) left no current page")
            XCTAssertTrue(store.selection.isSubset(of: Set(store.currentPage.visuals.map(\.id))), "\(label) ▸ \(id) selected a missing visual")
            _ = command.isOn?(store)
            if ModalGuard.opened.count > asked { panels.append("\(id) (\(ModalGuard.opened[asked...].joined(separator: ", ")))") }
            if store.status?.kind == .error { errors.append("\(id): \(store.status?.text ?? "")") }
            if Effects(store) == before, notes == 0, ModalGuard.opened.count == asked { quiet.append(id) }
        }
        return Sweep(ran: ran, quiet: quiet, panels: panels, errors: errors)
    }

    private struct Sweep { var ran: [String], quiet: [String], panels: [String], errors: [String] }

    /// The sweep found Distribute enabled, and doing nothing, with one visual selected.
    func testDistributeNeedsThreeVisuals() async throws {
        let store = await Smoke.emptyStore()
        let ids = [0.0, 100, 500].map { x in store.addVisual(.textBox, at: CGPoint(x: x, y: 40)) }
        for id in ids { store.updateVisual(id, invalidates: .layout) { $0.frame.width = 100 } }
        let distribute = try XCTUnwrap(AppCommands.command("format.distributeH"))
        store.selection = Set(ids.prefix(2))
        XCTAssertFalse(distribute.isEnabled(store))
        store.selection = Set(ids)
        XCTAssertTrue(distribute.isEnabled(store))
        AppCommands.perform(distribute, store)
        // 0…600 holds 300 pt of visuals: two gaps of 150.
        XCTAssertEqual(ids.compactMap { store.visual($0)?.frame.x }, [0, 250, 500])
    }

    func testEveryCommandRunsOnAnEmptyDocument() async {
        let result = await sweep("empty") { await Smoke.emptyStore() }
        XCTAssertGreaterThan(result.ran.count, 60)
        report("empty document", result)
    }

    func testEveryCommandRunsOnTheSampleWithAChartSelected() async {
        // One sample document, copied into a fresh store for every command.
        let base = await Smoke.sampleStore()
        let chart = Smoke.addVisual(.clusteredBar, [(.category, .column("Product", "Category")), (.category, .column("Product", "Subcategory")),
                                                    (.values, .measure("Sales", "Total Sales"))], to: base)
        await Smoke.settle(base)
        let document = base.doc, page = base.currentPageID
        let result = await sweep("sample") {
            let store = DocumentStore(document: document, services: .live())
            store.goToPage(page)
            store.selection = [chart]
            await Smoke.settle(store)
            return store
        }
        XCTAssertGreaterThan(result.ran.count, 120)
        for id in ["edit.delete", "edit.duplicate", "format.alignLeft", "drill.nextLevel", "drill.showAsTable", "format.editInteractions"] {
            XCTAssertTrue(result.ran.contains(id), "\(id) is not enabled with a chart selected")
        }
        report("sample with a chart selected", result)
    }

    private func report(_ label: String, _ result: Sweep) {
        let skipped = AppCommands.all.map(\.id).filter(Self.isSkipped)
        let text = """
            \(label): ran \(result.ran.count) commands; skipped \(skipped.joined(separator: ", "))
            asked for a panel (answered Cancel): \(result.panels.joined(separator: "; "))
            ended with an error message: \(result.errors.joined(separator: "; "))
            no visible effect: \(result.quiet.joined(separator: ", "))

            """
        print(text)
        if let folder = ProcessInfo.processInfo.environment["FACET_SMOKE_DUMP"] {
            try? text.write(to: URL(fileURLWithPath: folder).appendingPathComponent("commands-\(label.prefix(5)).txt"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: Views

    /// Hosts every workspace view, every pane and the whole window, laid out at real sizes.
    private func hostEverything(_ store: DocumentStore, _ label: String) async {
        for view in WorkspaceView.allCases {
            if view != .report {
                XCTAssertNotNil(Features.workspaceBuilders[view], "\(view.title) view has no builder, only a placeholder")
            }
            store.view = view
            let content: AnyView = view == .report ? AnyView(ReportCanvas()) : Features.workspace(view, store)
            let size = Smoke.host(content.environmentObject(store), size: CGSize(width: 1100, height: 700))
            XCTAssertTrue(size.width.isFinite && size.height.isFinite, "\(label) ▸ \(view.title) view")
            _ = await Smoke.bitmap(content.environmentObject(store), size: CGSize(width: 1100, height: 700))
        }
        store.view = .report
        for pane in InspectorPane.allCases {
            XCTAssertNotNil(Features.paneBuilders[pane], "the \(pane.title) pane has no builder, only a placeholder")
            let content = Features.pane(pane, store).environmentObject(store)
            Smoke.host(content, size: CGSize(width: 300, height: 800))
            guard let drawn = await Smoke.bitmap(content, size: CGSize(width: 300, height: 800)) else {
                XCTFail("\(label) ▸ \(pane.title) pane could not be drawn"); continue
            }
            XCTAssertGreaterThan(Smoke.ink(drawn).share, 0.001, "\(label) ▸ the \(pane.title) pane draws nothing")
        }
    }

    func testEveryViewAndPaneHostsOnAnEmptyDocument() async {
        let store = await Smoke.emptyStore()
        await hostEverything(store, "empty")
        await Smoke.settle(store)
        XCTAssertTrue(store.model.tables.isEmpty, "hosting the views changed the document")
    }

    func testEveryViewAndPaneHostsOnTheSampleWithAChartSelected() async {
        let store = await Smoke.sampleStore()
        let chart = Smoke.addVisual(.clusteredColumn, [(.category, .column("Product", "Category")), (.values, .measure("Sales", "Total Sales"))], to: store)
        await Smoke.settle(store)
        store.selection = [chart]
        let before = store.doc
        await hostEverything(store, "sample")
        await Smoke.settle(store)
        Smoke.assertSame(store.doc, before, "hosting the views changed the document")
    }

    func testTheWholeWindowLaysOutAtTheMinimumAndDefaultSizes() async {
        for sample in [false, true] {
            let handle = DocumentHandle()
            let store = StoreRegistry.shared.store(for: handle)
            if sample { AppCommands.run("data.sample", store) }
            await Smoke.settle(store)
            for size in [ShellMetrics.minimumWindow, CGSize(width: 1440, height: 900)] {
                let window = DocumentWindow(handle: handle)
                guard let drawn = await Smoke.bitmap(window, size: size, patience: 0.5) else {
                    XCTFail("the window could not be drawn at \(size)"); continue
                }
                XCTAssertGreaterThanOrEqual(Smoke.ink(drawn).colours, 4, "the \(sample ? "sample" : "empty") window at \(Int(size.width)) pt is flat")
            }
            StoreRegistry.shared.remove(handle.id)
        }
    }
}

/// Stands in for every modal panel and alert: records that one was asked for and answers Cancel
/// (the second button of an alert), so nothing waits for a click that cannot come.
@MainActor
enum ModalGuard {
    static var opened: [String] = []
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let cancel: @convention(block) (AnyObject) -> Int = { panel in
            ModalGuard.opened.append(panel is NSOpenPanel ? "open panel" : "save panel")
            return NSApplication.ModalResponse.cancel.rawValue
        }
        let dismiss: @convention(block) (AnyObject) -> Int = { _ in
            ModalGuard.opened.append("alert")
            return NSApplication.ModalResponse.alertSecondButtonReturn.rawValue
        }
        let runModal = NSSelectorFromString("runModal")
        // The classes the panels really are, which may be private subclasses.
        let panelClasses: [AnyClass] = [NSSavePanel.self, NSOpenPanel.self, object_getClass(NSSavePanel()), object_getClass(NSOpenPanel())]
            .compactMap { $0 }
        for cls in panelClasses { replace(runModal, in: cls, with: imp_implementationWithBlock(cancel)) }
        replace(runModal, in: NSAlert.self, with: imp_implementationWithBlock(dismiss))
    }

    private static func replace(_ selector: Selector, in cls: AnyClass, with imp: IMP) {
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        class_replaceMethod(cls, selector, imp, method_getTypeEncoding(method))
    }
}
