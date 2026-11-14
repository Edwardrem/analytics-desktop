import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Personalised visuals (the per-reader overlay), sorting in the reading view, and "See records".
@MainActor
final class PersonalizeTests: XCTestCase {
    private typealias F = ReportFixture
    private var suite = ""

    override func setUp() {
        super.setUp()
        Features.registerAll()
        suite = "personalize-tests-\(UUID().uuidString)"
        ReportRuntime.preferences = UserDefaults(suiteName: suite) ?? .standard
    }
    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        ReportRuntime.preferences = .standard
        super.tearDown()
    }

    private func names(_ v: VisualSpec, _ well: Well) -> [String] { v.fields(well).map(\.name) }

    func testNoPersonalizationLeavesTheVisualAlone() {
        let chart = F.chart()
        XCTAssertEqual(Personalize.apply(nil, to: chart), chart)
        XCTAssertEqual(Personalize.apply(Personalization(), to: chart), chart)
    }

    func testChangingTypeCarriesFieldsToTheNewShape() {
        let chart = F.chart()
        let p = Personalize.settingType(nil, .pie, saved: chart)
        let pie = Personalize.apply(p, to: chart)
        XCTAssertEqual(pie.type, .pie)
        // A pie has no Axis: the category moves to Legend, the value stays in Values.
        XCTAssertEqual(names(pie, .legend), ["Region"])
        XCTAssertEqual(names(pie, .values), ["Amount"])
        XCTAssertEqual(pie.id, chart.id, "it is still the same visual")
        // Choosing the saved type again is no personalisation at all.
        XCTAssertTrue(Personalize.settingType(p, .clusteredColumn, saved: chart).isEmpty)
    }

    func testChangingFieldsThenTypeKeepsTheReadersFields() {
        let chart = F.chart()
        var p = Personalize.settingFields(nil, well: .category, fields: [F.product], saved: chart)
        var shown = Personalize.apply(p, to: chart)
        XCTAssertEqual(names(shown, .category), ["Product"])
        XCTAssertEqual(names(shown, .values), ["Amount"])
        p = Personalize.settingType(p, .donut, saved: chart)
        shown = Personalize.apply(p, to: chart)
        XCTAssertEqual(shown.type, .donut)
        XCTAssertEqual(names(shown, .legend), ["Product"])
        XCTAssertEqual(names(shown, .values), ["Amount"])
        // Emptying a well leaves it empty rather than restoring the saved field.
        p = Personalize.settingFields(p, well: .legend, fields: [], saved: chart)
        XCTAssertEqual(names(Personalize.apply(p, to: chart), .legend), [])
    }

    func testSortFollowsTheFieldsAndDrillStateIsReset() {
        var chart = F.chart()
        chart.setFields(.category, [F.region, F.product])
        chart.drillLevel = 1
        chart.drillPath = [.string("North")]
        var p = Personalize.settingSort(nil, field: F.amount, descending: true)
        XCTAssertEqual(Personalize.apply(p, to: chart).sort, [SortSpec(field: F.amount, descending: true)])
        XCTAssertEqual(Personalize.apply(p, to: chart).drillLevel, 1, "sorting alone keeps the drill position")
        // Removing the sorted field drops the sort; cutting the hierarchy to one level returns to the top.
        p = Personalize.settingFields(p, well: .values, fields: [F.total], saved: chart)
        p = Personalize.settingFields(p, well: .category, fields: [F.product], saved: chart)
        let shown = Personalize.apply(p, to: chart)
        XCTAssertEqual(shown.sort, [])
        XCTAssertEqual(shown.drillLevel, 0)
        XCTAssertEqual(shown.drillPath, [])
        // "Default order" removes the reader's sort.
        XCTAssertNil(Personalize.settingSort(Personalize.settingSort(nil, field: F.amount, descending: false), field: nil, descending: false).sort)
    }

    func testPersonalisedVisualQueriesItsOwnFields() {
        let chart = F.chart()
        let shown = Personalize.apply(Personalize.settingFields(nil, well: .category, fields: [F.product], saved: chart), to: chart)
        let data = F.engine().visualData(spec: shown, request: VisualRequest())
        guard let c = data.indices(.category).first, let v = data.indices(.values).first else { return XCTFail("missing roles") }
        var totals: [String: Double] = [:]
        for row in 0..<data.table.rowCount { totals[data.table[row, c].asString] = data.table[row, v].asDouble }
        // Apple: 10 + 30 + 50; Pear: 20 + 40.
        XCTAssertEqual(totals, ["Apple": 90, "Pear": 60])
    }

    func testPersonalisationsAreKeptPerDocumentOutsideTheDocument() {
        let url = URL(fileURLWithPath: "/tmp/personalize-\(UUID().uuidString).facet")
        let store = F.store()
        store.fileURL = url
        let chart = store.addVisual(.clusteredColumn) { $0.setFields(.category, [F.region]); $0.setFields(.values, [F.amount]) }
        guard let saved = store.visual(chart) else { return XCTFail("chart missing") }
        let undoBefore = store.undoName
        let runtime = ReportRuntime.of(store)
        runtime.setPersonalization(Personalize.settingType(nil, .pie, saved: saved), for: chart)
        XCTAssertEqual(runtime.effectiveSpec(saved).type, .pie)
        XCTAssertEqual(store.visual(chart)?.type, .clusteredColumn, "the document is not edited")
        XCTAssertEqual(store.undoName, undoBefore, "and nothing lands in the undo history")
        XCTAssertTrue(runtime.hasPersonalizations(on: store.currentPage))

        // Another window on the same file sees the reader's changes.
        let other = F.store()
        other.fileURL = url
        XCTAssertEqual(ReportRuntime.of(other).personalization(for: chart)?.type, .pie)

        runtime.resetPersonalizations(on: store.currentPage)
        XCTAssertEqual(runtime.effectiveSpec(saved), saved)
        XCTAssertNil(ReportRuntime.preferences.data(forKey: Personalize.storageKey(for: url) ?? ""))
    }

    func testStorageDropsEmptyEntriesAndSurvivesBadData() {
        let a = UUID(), b = UUID()
        var sorted = Personalization(); sorted.sort = [SortSpec(field: F.amount, descending: true)]
        let back = Personalize.decode(Personalize.encode([a: sorted, b: Personalization()]))
        XCTAssertEqual(back, [a: sorted])
        XCTAssertEqual(Personalize.decode(Data("not json".utf8)), [:])
        XCTAssertEqual(Personalize.decode(nil), [:])
        XCTAssertNil(Personalize.storageKey(for: nil))
    }

    func testOnlyDataVisualsCanBePersonalised() {
        XCTAssertTrue(Personalize.canPersonalize(.clusteredColumn))
        XCTAssertTrue(Personalize.canPersonalize(.matrix))
        XCTAssertFalse(Personalize.canPersonalize(.slicer))
        XCTAssertFalse(Personalize.canPersonalize(.button))
        XCTAssertFalse(Personalize.canPersonalize(.keyInfluencers))
    }

    // MARK: See records

    func testSeeRecordsListsTheRowsBehindAPoint() {
        guard let spec = SeeRecords.recordsSpec(for: F.chart(), model: F.model()) else { return XCTFail("expected a records table") }
        XCTAssertEqual(spec.type, .table)
        XCTAssertEqual(spec.fields(.values).map(\.caption), ["Region", "Product", "Channel", "Amount", "Rows"])
        let request = SeeRecords.request(source: VisualRequest(), point: F.point(F.region, "North"))
        XCTAssertEqual(request.rowLimit, 1_000)
        let data = F.engine().visualData(spec: spec, request: request)
        XCTAssertNil(data.error)
        // North has two rows: Apple/Web/10 and Pear/Store/20, each standing for one row.
        XCTAssertEqual(data.table.rowCount, 2)
        let columns = data.indices(.values)
        guard columns.count == 5 else { return XCTFail("expected five columns, got \(columns.count)") }
        let amounts = Set((0..<data.table.rowCount).compactMap { data.table[$0, columns[3]].asDouble })
        XCTAssertEqual(amounts, [10, 20])
        XCTAssertEqual((0..<data.table.rowCount).compactMap { data.table[$0, columns[4]].asDouble }, [1, 1])
        XCTAssertEqual(Set((0..<data.table.rowCount).map { data.table[$0, columns[0]].asString }), ["North"])
    }

    func testMeasureOnlyVisualsShowTheDataPointInstead() {
        var chart = F.chart()
        chart.setFields(.values, [F.total])
        XCTAssertNil(SeeRecords.recordsSpec(for: chart, model: F.model()))
        let point = SeeRecords.pointSpec(for: chart)
        XCTAssertEqual(point.fields(.values).map(\.caption), ["Region", "Total"])
        let data = F.engine().visualData(spec: point, request: SeeRecords.request(source: VisualRequest(), point: F.point(F.region, "South")))
        XCTAssertEqual(data.table.rowCount, 1)
        let columns = data.indices(.values)
        XCTAssertEqual(columns.last.flatMap { data.table[0, $0].asDouble }, 70)   // South: 30 + 40
    }
}
