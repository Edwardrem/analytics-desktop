import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Filter pane rules (single selection, clear, reorder, Apply button), edit interactions, and
/// slicers that wait for an "Apply all slicers" button.
@MainActor
final class FilterInteractionTests: XCTestCase {
    private typealias F = ReportFixture

    override func setUp() {
        super.setUp()
        Features.registerAll()
    }

    private func basic(_ field: FieldRef, _ values: [String]) -> FilterSpec {
        var f = FilterSpec(field: field)
        f.values = values.map(Value.string)
        return f
    }

    /// A store whose only page holds the given visuals.
    private func store(_ visuals: [VisualSpec], applyButton: Bool = false, pages extra: [Page] = []) -> DocumentStore {
        let store = F.store()
        var page = Page(name: "Overview")
        page.visuals = visuals
        store.mutate("Set Up", invalidates: .layout) { d in
            d.report.pages = [page] + extra
            d.report.settings.filterPaneApplyButton = applyButton
        }
        return store
    }

    // MARK: Filter rules

    func testSingleSelectionReplacesInsteadOfToggling() {
        var f = basic(F.region, ["North"])
        XCTAssertEqual(FilterTools.toggling(f, .string("South")).values, [.string("North"), .string("South")])
        XCTAssertEqual(FilterTools.toggling(f, .string("North")).values, [], "a list filter can be emptied by clicking")
        f.requireSingleSelection = true
        XCTAssertEqual(FilterTools.toggling(f, .string("South")).values, [.string("South")])
        XCTAssertEqual(FilterTools.toggling(f, .string("North")).values, [.string("North")], "the one choice stays chosen")
    }

    func testRequiringSingleSelectionKeepsTheFirstValueAndDropsExclude() {
        var f = basic(F.region, ["South", "North"])
        f.isInverted = true
        let single = FilterTools.requiringSingleSelection(f, true)
        XCTAssertTrue(single.requireSingleSelection)
        XCTAssertEqual(single.values, [.string("South")])
        XCTAssertFalse(single.isInverted)
        XCTAssertEqual(FilterTools.requiringSingleSelection(single, false).values, [.string("South")])
    }

    func testClearingKeepsTheCardButRestrictsNothing() {
        var relative = FilterSpec(field: F.region, kind: .relativeDate)
        XCTAssertFalse(relative.isEmpty, "a relative date filter always restricts")
        relative = FilterTools.cleared(relative)
        XCTAssertEqual(relative.kind, .basic)
        XCTAssertTrue(relative.isEmpty)
        var top = FilterSpec(field: F.region, kind: .topN)
        top.topN.by = F.amount; top.topN.count = 3
        XCTAssertTrue(FilterTools.cleared(top).isEmpty)
    }

    func testClearAllLeavesLockedFiltersAlone() {
        var report = Report()
        var locked = basic(F.region, ["North"]); locked.isLocked = true
        report.filters = [basic(F.product, ["Apple"])]
        report.pages[0].filters = [locked, basic(F.channel, ["Web"])]
        var chart = F.chart(); chart.filters = [basic(F.region, ["South"])]
        report.pages[0].visuals = [chart]
        XCTAssertEqual(FilterTools.clearAll(&report, pageIndex: 0), 3)
        XCTAssertTrue(report.filters[0].isEmpty)
        XCTAssertEqual(report.pages[0].filters[0].values, [.string("North")], "locked")
        XCTAssertTrue(report.pages[0].filters[1].isEmpty)
        XCTAssertTrue(report.pages[0].visuals[0].filters[0].isEmpty)
        XCTAssertEqual(FilterTools.clearAll(&report, pageIndex: 0), 0, "nothing left to clear")
    }

    func testMovingAFilterStaysInsideTheList() {
        let a = basic(F.region, []), b = basic(F.product, []), c = basic(F.channel, [])
        XCTAssertEqual(FilterTools.moved([a, b, c], id: c.id, by: -1).map(\.id), [a.id, c.id, b.id])
        XCTAssertEqual(FilterTools.moved([a, b, c], id: a.id, by: -1).map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(FilterTools.moved([a, b, c], id: a.id, by: 5).map(\.id), [b.id, c.id, a.id])
    }

    func testSummaryReadsLikeTheFilterCard() {
        XCTAssertEqual(FilterTools.summary(basic(F.region, [])), "is (All)")
        XCTAssertEqual(FilterTools.summary(basic(F.region, ["North", ""])), "is North, (Blank)")
        var exclude = basic(F.region, ["East"]); exclude.isInverted = true
        XCTAssertEqual(FilterTools.summary(exclude), "is not East")
        var relative = FilterSpec(field: F.region, kind: .relativeDate)
        relative.relative.count = 3; relative.relative.unit = .months
        XCTAssertEqual(FilterTools.summary(relative), "is in the last 3 months including today")
        relative.relative.direction = .this
        XCTAssertEqual(FilterTools.summary(relative), "is in this month")
    }

    func testRenameAndReorderThroughTheStore() {
        let s = store([F.chart()])
        s.addFilter(F.region, scope: .page)
        s.addFilter(F.product, scope: .page)
        let ids = s.currentPage.filters.map(\.id)
        s.renameFilter(id: ids[1], scope: .page, to: "  Fruit ")
        XCTAssertEqual(s.currentPage.filters[1].displayName, "Fruit")
        s.moveFilter(id: ids[1], scope: .page, by: -1)
        XCTAssertEqual(s.currentPage.filters.map(\.id), [ids[1], ids[0]])
        XCTAssertEqual(s.undoName, "Reorder Filters")
        s.renameFilter(id: ids[1], scope: .page, to: "")
        XCTAssertNil(s.currentPage.filters[0].displayName, "an empty name shows the field's name again")
    }

    // MARK: Apply button

    func testWithoutAnApplyButtonFilterEditsApplyAtOnce() {
        let chart = F.chart()
        let s = store([chart])
        s.addFilter(F.region, scope: .page)
        let id = s.currentPage.filters[0].id
        s.updateFilter(id: id, scope: .page) { $0.values = [.string("North")] }
        XCTAssertEqual(s.filters(for: chart, on: s.currentPage).map(\.values), [[.string("North")]])
        XCTAssertFalse(ReportRuntime.of(s).filtersPending)
    }

    func testApplyButtonHoldsFilterEditsUntilApply() {
        let chart = F.chart()
        let s = store([chart], applyButton: true)
        let runtime = ReportRuntime.of(s)
        s.addFilter(F.region, scope: .page)
        let id = s.currentPage.filters[0].id
        s.updateFilter(id: id, scope: .page) { $0.values = [.string("North")] }
        XCTAssertEqual(s.currentPage.filters[0].values, [.string("North")], "the edit itself is saved")
        XCTAssertTrue(runtime.filtersPending)
        XCTAssertEqual(s.filters(for: chart, on: s.currentPage), [], "the visuals keep the filters they last ran with")

        // The chart still shows every region: North 30, South 70, East 50.
        let engine = F.engine()
        var data = engine.visualData(spec: chart, request: s.request(for: chart, on: s.currentPage))
        XCTAssertEqual(data.table.rowCount, 3)

        s.applyPendingFilters()
        XCTAssertFalse(runtime.filtersPending)
        data = engine.visualData(spec: chart, request: s.request(for: chart, on: s.currentPage))
        XCTAssertEqual(data.table.rowCount, 1)
        XCTAssertEqual(data.table[0, 1].asDouble, 30)
    }

    func testPresentationEditsAndUndoLeaveNothingToApply() {
        let chart = F.chart()
        let s = store([chart], applyButton: true)
        s.addFilter(F.region, scope: .report)
        s.applyPendingFilters()
        let id = s.report.filters[0].id
        s.updateFilter(id: id, scope: .report) { $0.isLocked = true; $0.isHidden = true }
        s.renameFilter(id: id, scope: .report, to: "Where")
        XCTAssertFalse(ReportRuntime.of(s).filtersPending, "locking, hiding and renaming change nothing a visual shows")
        s.updateFilter(id: id, scope: .report) { $0.values = [.string("East")] }
        XCTAssertTrue(ReportRuntime.of(s).filtersPending)
        s.undo()
        XCTAssertFalse(ReportRuntime.of(s).filtersPending, "back where the visuals already are")
    }

    func testClearAllFiltersWaitsForApplyToo() {
        var chart = F.chart(); chart.filters = [basic(F.region, ["South"])]
        let s = store([chart], applyButton: true)
        s.clearAllFilters()
        XCTAssertTrue(s.currentPage.visuals[0].filters[0].isEmpty)
        XCTAssertEqual(s.filters(for: s.currentPage.visuals[0], on: s.currentPage).map(\.values), [[.string("South")]])
        AppCommands.run("filters.apply", s)
        XCTAssertEqual(s.filters(for: s.currentPage.visuals[0], on: s.currentPage), [])
    }

    func testTurningTheApplyButtonOffAppliesWhatWaits() {
        let chart = F.chart()
        let s = store([chart], applyButton: true)
        s.addFilter(F.product, scope: .page)
        s.updateFilter(id: s.currentPage.filters[0].id, scope: .page) { $0.values = [.string("Pear")] }
        XCTAssertEqual(AppCommands.command("filters.apply")?.isEnabled(s), true)
        AppCommands.run("filters.applyButton", s)
        XCTAssertFalse(s.report.settings.filterPaneApplyButton)
        XCTAssertEqual(s.filters(for: chart, on: s.currentPage).map(\.values), [[.string("Pear")]])
        XCTAssertEqual(AppCommands.command("filters.apply")?.isEnabled(s), false)
    }

    // MARK: Edit interactions

    func testDefaultInteractionDependsOnSourceAndTarget() {
        let chart = F.chart("A"), other = F.chart("B")
        var table = VisualSpec(type: .table, frame: Frame(x: 0, y: 0, width: 100, height: 100))
        table.setFields(.values, [F.region])
        var slicer = VisualSpec(type: .slicer, frame: Frame(x: 0, y: 0, width: 100, height: 100))
        slicer.setFields(.field, [F.channel])
        let s = store([chart, other, table, slicer])
        let page = s.currentPage
        XCTAssertEqual(s.interaction(from: chart.id, to: other, on: page), .highlight, "the report default")
        XCTAssertEqual(s.interaction(from: chart.id, to: table, on: page), .filter, "a table cannot show a highlight")
        XCTAssertEqual(s.interaction(from: slicer.id, to: other, on: page), .filter, "a slicer only filters")
        XCTAssertFalse(InteractionRules.canHighlight(from: slicer, to: other))
        XCTAssertTrue(InteractionRules.canHighlight(from: chart, to: other))
        XCTAssertFalse(InteractionRules.canEdit(VisualSpec(type: .shape, frame: chart.frame)))
    }

    func testChosenInteractionsShapeTheRequest() {
        let chart = F.chart("A"), other = F.chart("B", category: F.product), card = F.card()
        let s = store([chart, other, card])
        s.updatePage(name: "Edit Interactions") { p in p.interactions[chart.id] = [other.id: .none] }
        s.selectPoints([F.point(F.region, "North")], in: chart.id, additive: false)
        let page = s.currentPage
        XCTAssertTrue(s.request(for: other, on: page).crossFilters.isEmpty)
        XCTAssertTrue(s.request(for: other, on: page).highlights.isEmpty)
        XCTAssertEqual(s.request(for: card, on: page).crossFilters.count, 1, "a card is filtered")
        s.updatePage(name: "Edit Interactions") { p in p.interactions[chart.id] = [other.id: .highlight] }
        XCTAssertEqual(s.request(for: other, on: s.currentPage).highlights.count, 1)
    }

    func testEditInteractionsNeedsADataVisual() {
        let shape = VisualSpec(type: .shape, frame: Frame(x: 0, y: 0, width: 50, height: 50))
        let chart = F.chart()
        let s = store([shape, chart])
        s.selection = [shape.id]
        XCTAssertEqual(AppCommands.command("format.editInteractions")?.isEnabled(s), false)
        s.selection = [chart.id]
        AppCommands.run("format.editInteractions", s)
        XCTAssertEqual(s.editInteractionsFor, chart.id)
    }

    // MARK: Apply all slicers

    private func slicerPages() -> (overview: Page, other: Page, slicer: VisualSpec, synced: VisualSpec, button: VisualSpec, chart: VisualSpec) {
        var slicer = VisualSpec(type: .slicer, frame: Frame(x: 0, y: 0, width: 100, height: 100), name: "Channel")
        slicer.setFields(.field, [F.channel]); slicer.syncGroup = "Channel"
        var synced = slicer; synced.id = UUID(); synced.isHidden = true
        var button = VisualSpec(type: .button, frame: Frame(x: 0, y: 120, width: 100, height: 40))
        var action = ActionSpec(); action.kind = .applyAllSlicers; button.action = action
        let chart = F.chart()
        var overview = Page(name: "Overview"); overview.visuals = [slicer, button, chart]
        var other = Page(name: "Other"); other.visuals = [synced]
        return (overview, other, slicer, synced, button, chart)
    }

    func testSlicersWaitForTheApplyAllButton() {
        let r = slicerPages()
        let s = F.store()
        s.mutate("Set Up", invalidates: .layout) { $0.report.pages = [r.overview, r.other] }
        let runtime = ReportRuntime.of(s)
        var web = SlicerState(); web.selected = [.string("Web")]
        let button = s.context(for: r.button)
        XCTAssertFalse(button.canRunAction(r.button.action ?? ActionSpec()), "nothing to apply yet")

        s.changeSlicer(web, for: r.slicer.id)
        XCTAssertNil(s.currentPage.visual(r.slicer.id)?.slicerState, "not saved yet")
        XCTAssertEqual(runtime.withPendingSlicer(r.slicer).slicerState, web, "but drawn as chosen")
        XCTAssertTrue(s.request(for: r.chart, on: s.currentPage).slicers.isEmpty, "and the chart is not filtered yet")
        XCTAssertTrue(s.context(for: r.button).canRunAction(r.button.action ?? ActionSpec()))

        s.perform(r.button.action ?? ActionSpec(), from: r.button.id)
        XCTAssertEqual(s.currentPage.visual(r.slicer.id)?.slicerState, web)
        XCTAssertEqual(s.report.pages[1].visual(r.synced.id)?.slicerState, web, "the synced slicer follows")
        XCTAssertEqual(s.request(for: r.chart, on: s.currentPage).slicers.count, 1)
        XCTAssertTrue(runtime.pendingSlicers(on: s.currentPage).isEmpty)
        XCTAssertEqual(s.undoName, "Apply All Slicers")
    }

    func testWithoutTheButtonSlicersApplyAtOnce() {
        var r = slicerPages()
        r.overview.visuals.removeAll { $0.id == r.button.id }
        let s = F.store()
        s.mutate("Set Up", invalidates: .layout) { $0.report.pages = [r.overview, r.other] }
        var store = SlicerState(); store.selected = [.string("Store")]
        s.changeSlicer(store, for: r.slicer.id)
        XCTAssertEqual(s.currentPage.visual(r.slicer.id)?.slicerState, store)
    }

    func testClearAllSlicersClearsSyncedAndWaitingSelections() {
        var r = slicerPages()
        var web = SlicerState(); web.selected = [.string("Web")]
        r.overview.visuals[0].slicerState = web
        r.other.visuals[0].slicerState = web
        let s = F.store()
        s.mutate("Set Up", invalidates: .layout) { $0.report.pages = [r.overview, r.other] }
        var store = SlicerState(); store.selected = [.string("Store")]
        s.changeSlicer(store, for: r.slicer.id)
        s.clearAllSlicers()
        XCTAssertNil(s.currentPage.visual(r.slicer.id)?.slicerState)
        XCTAssertNil(s.report.pages[1].visual(r.synced.id)?.slicerState)
        XCTAssertTrue(ReportRuntime.of(s).pendingSlicers.isEmpty)
    }

    func testReportApplyButtonsReachEverySlicer() {
        let r = slicerPages()
        let s = store([r.slicer])
        XCTAssertFalse(s.context(for: r.slicer).slicerApplyButtons)
        s.mutate("Query Reduction", invalidates: .layout) { $0.report.settings.slicerApplyButtons = true }
        XCTAssertTrue(s.context(for: r.slicer).slicerApplyButtons)
    }
}
