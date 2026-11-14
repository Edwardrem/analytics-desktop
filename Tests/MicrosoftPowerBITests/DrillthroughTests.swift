import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Drillthrough pages, the filters a drillthrough carries, the back button, and drillthrough / conditional buttons.
@MainActor
final class DrillthroughTests: XCTestCase {
    private typealias F = ReportFixture

    override func setUp() {
        super.setUp()
        Features.registerAll()
    }

    /// A report with a source page (chart by Region, slicer on Channel) and a "Details" page that drills through on Region.
    private func report(keepAll: Bool = true) -> (report: Report, source: Page, details: Page, chart: VisualSpec, slicer: VisualSpec) {
        var source = Page(name: "Overview")
        let chart = F.chart()
        var slicer = VisualSpec(type: .slicer, frame: Frame(x: 320, y: 0, width: 100, height: 100), name: "Slicer")
        slicer.setFields(.field, [F.channel])
        source.visuals = [chart, slicer]
        var details = Page(name: "Details")
        details.drillthroughFilters = [FilterSpec(field: F.region)]
        details.keepAllFiltersOnDrillthrough = keepAll
        var report = Report()
        report.pages = [source, details]
        return (report, source, details, chart, slicer)
    }

    func testTargetsArePagesWithAMatchingDrillthroughField() {
        var r = report()
        var tooltip = Page(name: "Tip"); tooltip.isTooltipPage = true
        tooltip.drillthroughFilters = [FilterSpec(field: F.region)]
        r.report.pages.append(tooltip)
        XCTAssertEqual(Drillthrough.targets(for: F.point(F.region, "North"), in: r.report, from: r.source.id).map(\.name), ["Details"])
        // A point on another column has nowhere to go; neither does a point already on the destination page.
        XCTAssertEqual(Drillthrough.targets(for: F.point(F.product, "Apple"), in: r.report, from: r.source.id), [])
        XCTAssertEqual(Drillthrough.targets(for: F.point(F.region, "North"), in: r.report, from: r.details.id), [])
        // The aggregation a visual puts on the column does not matter.
        let summed = DataPointSelection(fields: [FieldRef.column("Sales", "Region", .count)], values: [.string("North")])
        XCTAssertEqual(Drillthrough.targets(for: summed, in: r.report, from: r.source.id).count, 1)
    }

    func testWithoutKeepAllOnlyTheDrillthroughFieldTravels() {
        var r = report(keepAll: false)
        r.source.filters = [Drillthrough.basic(F.product, [.string("Apple")])]
        let point = DataPointSelection(fields: [F.region, F.product], values: [.string("North"), .string("Pear")])
        let filters = Drillthrough.filters(point: point, target: r.details, sourcePage: r.source, sourceVisual: r.chart, selections: [:])
        XCTAssertEqual(filters.count, 1)
        XCTAssertEqual(filters.first?.id, r.details.drillthroughFilters[0].id, "the value lands on the page's own drillthrough field")
        XCTAssertEqual(filters.first?.values, [.string("North")])
    }

    func testKeepAllCarriesPointFieldsPageFiltersSlicersAndSelections() {
        var r = report()
        r.source.filters = [Drillthrough.basic(F.product, [.string("Apple")]), FilterSpec(field: F.channel)]   // second one is empty
        var slicerState = SlicerState(); slicerState.selected = [.string("Web")]
        r.source.visuals[1].slicerState = slicerState
        var other = F.chart("Other", category: F.product)
        other.id = UUID()
        r.source.visuals.append(other)
        var topN = FilterSpec(field: F.region, kind: .topN); topN.topN.by = F.amount
        var chart = r.chart; chart.filters = [topN]
        let selections = [other.id: [F.point(F.product, "Pear"), F.point(F.product, "Apple")], chart.id: [F.point(F.region, "South")]]
        let filters = Drillthrough.filters(point: F.point(F.region, "North"), target: r.details, sourcePage: r.source,
                                           sourceVisual: chart, selections: selections)
        // Region = North (drillthrough field), then the page filter on Product, then the slicer on Channel.
        // The other visual's Product selection is already covered by the page filter on Product; the source
        // visual's own selection and its Top N do not travel; the empty page filter is skipped.
        XCTAssertEqual(filters.map { "\($0.field.name)=\($0.values.map(\.asString).joined(separator: ","))" },
                       ["Region=North", "Product=Apple", "Channel=Web"])
    }

    func testKeepAllCarriesOtherVisualsSelectionsWhenNothingElseCoversTheField() {
        var r = report()
        var other = F.chart("Other", category: F.product)
        other.id = UUID()
        r.source.visuals.append(other)
        let selections = [other.id: [F.point(F.product, "Pear"), F.point(F.product, "Apple")]]
        let filters = Drillthrough.filters(point: F.point(F.region, "North"), target: r.details, sourcePage: r.source,
                                           sourceVisual: r.chart, selections: selections)
        XCTAssertEqual(filters.map(\.field.name), ["Region", "Product"])
        XCTAssertEqual(filters.last?.values, [.string("Pear"), .string("Apple")])
        // Unless the author switched that interaction off.
        r.source.interactions[other.id] = [r.chart.id: InteractionMode.none]
        XCTAssertEqual(Drillthrough.filters(point: F.point(F.region, "North"), target: r.details, sourcePage: r.source,
                                            sourceVisual: r.chart, selections: selections).map(\.field.name), ["Region"])
    }

    func testSlicerStatesBecomeFilters() {
        var range = SlicerState(); range.rangeLow = .int(10); range.rangeHigh = .int(40)
        let f = Drillthrough.filter(forSlicer: [FieldRef.column("Sales", "Amount")], state: range)
        XCTAssertEqual(f?.kind, .advanced)
        XCTAssertEqual(f?.conditions, [FilterCondition(op: .greaterOrEqual, value: .int(10)), FilterCondition(op: .lessOrEqual, value: .int(40))])
        var text = SlicerState(); text.text = "App"
        XCTAssertEqual(Drillthrough.filter(forSlicer: [F.product], state: text)?.conditions, [FilterCondition(op: .contains, value: .string("App"))])
        XCTAssertNil(Drillthrough.filter(forSlicer: [F.product], state: SlicerState()))
        XCTAssertNil(Drillthrough.filter(forSlicer: [], state: text))
    }

    func testDisplayShowsArrivedValuesOnTheDefinedFields() {
        let definition = FilterSpec(field: F.region)
        var arrived = definition; arrived.values = [.string("North")]
        let kept = Drillthrough.basic(F.product, [.string("Apple")])
        XCTAssertEqual(Drillthrough.display(definitions: [definition], applied: []), [definition])
        XCTAssertEqual(Drillthrough.display(definitions: [definition], applied: [kept, arrived]), [arrived, kept])
    }

    func testAddingADrillthroughFieldAddsOneBackButton() {
        let store = F.store()
        XCTAssertFalse(store.currentPage.isDrillthroughPage)
        store.addFilter(F.region, scope: .drillthrough)
        XCTAssertEqual(store.currentPage.drillthroughFilters.map(\.field.name), ["Region"])
        let buttons = store.currentPage.visuals.filter { $0.type == .button }
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(buttons.first?.action?.kind, .back)
        XCTAssertEqual(buttons.first?.fmt("button", "icon"), .string("back"))
        // A second field, or the same one again, adds no second button and no duplicate field.
        store.addFilter(F.product, scope: .drillthrough)
        store.addFilter(F.region, scope: .drillthrough)
        XCTAssertEqual(store.currentPage.drillthroughFilters.map(\.field.name), ["Region", "Product"])
        XCTAssertEqual(store.currentPage.visuals.filter { $0.type == .button }.count, 1)
        // Measures cannot be drillthrough fields.
        store.addFilter(F.total, scope: .drillthrough)
        XCTAssertEqual(store.currentPage.drillthroughFilters.count, 2)
        // One undo step removes the field and its back button together.
        store.undo(); store.undo()
        XCTAssertFalse(store.currentPage.isDrillthroughPage)
        XCTAssertTrue(store.currentPage.visuals.isEmpty)
    }

    func testDrillingThroughFiltersTheDestinationAndBackClearsIt() {
        let store = F.store()
        let chart = store.addVisual(.clusteredColumn) { $0.setFields(.category, [F.region]); $0.setFields(.values, [F.amount]) }
        let source = store.currentPageID
        store.addPage(named: "Details")
        let details = store.currentPageID
        store.addFilter(F.region, scope: .drillthrough)
        let card = store.addVisual(.card) { $0.setFields(.values, [F.amount]) }
        store.goToPage(source)

        store.drill(.drillthrough(F.point(F.region, "South"), pageID: nil), in: chart)
        XCTAssertEqual(store.currentPageID, details)
        XCTAssertEqual(store.drillthroughDisplay.map { $0.values }, [[.string("South")]])
        guard let spec = store.visual(card) else { return XCTFail("card missing") }
        XCTAssertEqual(store.filters(for: spec, on: store.currentPage).map(\.values), [[.string("South")]])
        // South = 30 + 40.
        let request = store.request(for: spec, on: store.currentPage)
        XCTAssertEqual(F.number(F.engine().visualData(spec: spec, request: request)), 70)

        store.perform({ var a = ActionSpec(); a.kind = .back; return a }())
        XCTAssertEqual(store.currentPageID, source)
        XCTAssertNil(store.drillthroughFilters[details])
        // A point with no drillthrough page goes nowhere and says why.
        store.drill(.drillthrough(F.point(F.product, "Apple"), pageID: nil), in: chart)
        XCTAssertEqual(store.currentPageID, source)
        XCTAssertEqual(store.status?.kind, .info)
    }

    func testDrillthroughButtonIsActiveOnlyWithAValidSelection() {
        let r = report()
        var action = ActionSpec(); action.kind = .drillthrough
        XCTAssertFalse(ReportActions.canRun(action, selections: [:], page: r.source, report: r.report))
        let onRegion = [r.chart.id: [F.point(F.region, "North")]]
        XCTAssertTrue(ReportActions.canRun(action, selections: onRegion, page: r.source, report: r.report))
        XCTAssertFalse(ReportActions.canRun(action, selections: [r.chart.id: [F.point(F.product, "Apple")]], page: r.source, report: r.report))
        // Bound to a page the selection cannot reach, it stays inactive.
        action.pageID = r.source.id
        XCTAssertFalse(ReportActions.canRun(action, selections: onRegion, page: r.source, report: r.report))
        action.pageID = r.details.id
        XCTAssertTrue(ReportActions.canRun(action, selections: onRegion, page: r.source, report: r.report))
        // Other actions are always available.
        var back = ActionSpec(); back.kind = .back
        XCTAssertTrue(ReportActions.canRun(back, selections: [:], page: r.source, report: r.report))
    }

    func testConditionalDestinationResolvesByName() {
        var r = report()
        r.report.bookmarks = [Bookmark(name: "Year view", pageID: r.source.id)]
        var nav = ActionSpec(); nav.kind = .pageNavigation; nav.conditionalMeasure = F.destination
        guard case .run(let resolved) = ReportActions.resolve(nav, measure: "Destination", value: .string(" details "), report: r.report) else {
            return XCTFail("expected a destination")
        }
        XCTAssertEqual(resolved.pageID, r.details.id)
        XCTAssertNil(resolved.conditionalMeasure)
        // Unknown names and blanks resolve to nothing.
        if case .run = ReportActions.resolve(nav, measure: "Destination", value: .string("Nowhere"), report: r.report) { XCTFail("no such page") }
        if case .run = ReportActions.resolve(nav, measure: "Destination", value: .null, report: r.report) { XCTFail("blank") }
        if case .run = ReportActions.resolve(nav, measure: "Destination", value: nil, report: r.report) { XCTFail("no value") }
        var bookmark = ActionSpec(); bookmark.kind = .bookmark
        guard case .run(let b) = ReportActions.resolve(bookmark, measure: "M", value: .string("Year View"), report: r.report) else {
            return XCTFail("expected a bookmark")
        }
        XCTAssertEqual(b.bookmarkID, r.report.bookmarks[0].id)
        var url = ActionSpec(); url.kind = .webURL
        guard case .run(let u) = ReportActions.resolve(url, measure: "M", value: .string("https://example.com/a"), report: r.report) else {
            return XCTFail("expected a URL")
        }
        XCTAssertEqual(u.url, "https://example.com/a")
    }

    func testConditionalMeasureIsEvaluatedByTheEngine() throws {
        // All rows: 150 > 100 → "Details". Filtered to North (30) → "Nowhere".
        let engine = F.engine()
        XCTAssertEqual(try engine.scalar(F.destination.daxReference, filters: []).asString, "Details")
        XCTAssertEqual(try engine.scalar(F.destination.daxReference, filters: [Drillthrough.basic(F.region, [.string("North")])]).asString, "Nowhere")
    }
}
