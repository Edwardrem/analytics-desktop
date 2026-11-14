import XCTest
import AppKit
import FacetCore
import FacetVisuals
@testable import FacetDAX
@testable import MicrosoftPowerBI

/// End to end on the sample: a page built with the gallery and Data pane commands, then clicked,
/// sliced, drilled and filtered through the same callbacks the canvas wires into every visual
/// (`store.context(for:)`), the Edit Interactions picker and the Filters pane.
///
/// Expected numbers are summed here from the Sales rows joined to their product, customer and day
/// (`SampleFacts`); "today" is pinned to Monday 15 June 2026, inside the sample's three years.
@MainActor
final class InteractionSmokeTests: XCTestCase {
    private let category = FieldRef.column("Product", "Category")
    private let subcategory = FieldRef.column("Product", "Subcategory")
    private let product = FieldRef.column("Product", "Product")
    private let segment = FieldRef.column("Customer", "Segment")
    private let country = FieldRef.column("Customer", "Country")
    private let day = FieldRef.column("Date", "Date")
    private let orderDate = FieldRef.column("Sales", "Order Date")
    private let unitPrice = FieldRef.column("Sales", "Unit Price")
    private let sales = FieldRef.measure("Sales", "Total Sales")
    private var savedClock: (() -> Date)?

    override func setUp() async throws {
        try await super.setUp()
        let today = try XCTUnwrap(DateParsing.parse("2026-06-15T12:00:00Z"))
        savedClock = PureDate.now
        PureDate.now = { today }
    }

    override func tearDown() async throws {
        if let savedClock { PureDate.now = savedClock }
        try await super.tearDown()
    }

    /// The sample on a fresh page of its own.
    private func samplePage() async -> (DocumentStore, SampleFacts) {
        let store = await Smoke.sampleStore()
        AppCommands.run("insert.page", store)
        return (store, SampleFacts(store))
    }

    // MARK: Cross-filter and cross-highlight

    func testSelectingADataPointHighlightsAndFiltersTheOtherVisuals() async throws {
        let (store, facts) = await samplePage()
        let columns = Smoke.addVisual(.clusteredColumn, [(.category, category), (.values, sales)], to: store)
        let donut = Smoke.addVisual(.donut, [(.legend, segment), (.values, sales)], to: store)
        let table = Smoke.addVisual(.table, [(.values, country), (.values, sales)], to: store)
        let card = Smoke.addVisual(.card, [(.values, sales)], to: store)
        await Smoke.settle(store)
        let total = facts.total()
        XCTAssertEqual(Smoke.card(store, card), total, accuracy: 0.01)
        assertSameSeries(Smoke.series(store, columns, labels: .category), facts.totals(by: \.category), "columns")

        // Click the Audio column.
        let audio = Smoke.point(store, columns, category: "Audio")
        XCTAssertEqual(audio.values, [.string("Audio")])
        store.context(for: try XCTUnwrap(store.visual(columns))).onSelect([audio], false)
        await Smoke.settle(store)
        let isAudio: (SampleFacts.Row) -> Bool = { $0.category == "Audio" }
        // The donut can highlight: every segment keeps its slice, with Audio's part lit.
        assertSameSeries(Smoke.series(store, donut, labels: .legend, baseline: true), facts.totals(by: \.segment), "donut baseline")
        assertSameSeries(Smoke.series(store, donut, labels: .legend), facts.totals(by: \.segment, where: isAudio), "donut highlight")
        // A table and a card cannot highlight, so they are filtered.
        XCTAssertNil(store.visualData[table]?.baseline)
        assertSameSeries(Smoke.rows(store, table), facts.totals(by: \.country, where: isAudio), "table")
        XCTAssertEqual(Smoke.card(store, card), facts.total(where: isAudio), accuracy: 0.01)
        // The clicked visual itself still shows every category.
        assertSameSeries(Smoke.series(store, columns, labels: .category), facts.totals(by: \.category), "columns after the click")
        XCTAssertEqual(store.context(for: try XCTUnwrap(store.visual(columns))).selection.map(\.key), [audio.key])

        // ⌘-click adds Home to the selection.
        store.context(for: try XCTUnwrap(store.visual(columns))).onSelect([Smoke.point(store, columns, category: "Home")], true)
        await Smoke.settle(store)
        XCTAssertEqual(Smoke.card(store, card), facts.total { $0.category == "Audio" || $0.category == "Home" }, accuracy: 0.01)

        // Edit Interactions: the donut is filtered instead, the card ignores the columns.
        let picks: [(UUID, InteractionMode)] = [(donut, .filter), (card, .none)]
        for (target, mode) in picks {
            store.updatePage(name: "Edit Interactions", invalidates: .visuals(nil)) { p in
                var m = p.interactions[columns] ?? [:]
                m[target] = mode
                p.interactions[columns] = m
            }
        }
        await Smoke.settle(store)
        let audioOrHome: (SampleFacts.Row) -> Bool = { $0.category == "Audio" || $0.category == "Home" }
        XCTAssertNil(store.visualData[donut]?.baseline, "a filtered visual has no highlight baseline")
        assertSameSeries(Smoke.series(store, donut, labels: .legend), facts.totals(by: \.segment, where: audioOrHome), "donut filtered")
        XCTAssertEqual(Smoke.card(store, card), total, accuracy: 0.01, "an interaction of None leaves the card alone")

        // Clicking empty space clears the selection: everything shows all rows again.
        store.context(for: try XCTUnwrap(store.visual(columns))).onSelect([], false)
        await Smoke.settle(store)
        assertSameSeries(Smoke.series(store, donut, labels: .legend), facts.totals(by: \.segment), "donut cleared")
        assertSameSeries(Smoke.rows(store, table), facts.totals(by: \.country), "table cleared")

        // A slice of the donut highlights the columns the other way round.
        let enterprise = Smoke.point(store, donut, row: "Enterprise", in: .legend)
        store.context(for: try XCTUnwrap(store.visual(donut))).onSelect([enterprise], false)
        await Smoke.settle(store)
        assertSameSeries(Smoke.series(store, columns, labels: .category, baseline: true), facts.totals(by: \.category), "columns baseline")
        assertSameSeries(Smoke.series(store, columns, labels: .category), facts.totals(by: \.category) { $0.segment == "Enterprise" },
                         "columns highlight")
        XCTAssertEqual(Smoke.card(store, card), facts.total { $0.segment == "Enterprise" }, accuracy: 0.01)
        // Clicking the same slice again clears it.
        store.context(for: try XCTUnwrap(store.visual(donut))).onSelect([enterprise], false)
        await Smoke.settle(store)
        XCTAssertNil(store.visualData[columns]?.baseline)
        XCTAssertEqual(Smoke.card(store, card), total, accuracy: 0.01)
        // None of this is an edit except the interaction choices.
        XCTAssertEqual(store.undoName, "Edit Interactions")
    }

    // MARK: Slicers

    /// Sets a slicer's state through the callback its view calls, then waits for the page.
    private func slice(_ store: DocumentStore, _ slicer: UUID, _ change: (inout SlicerState) -> Void) async throws {
        var state = SlicerState()
        change(&state)
        store.context(for: try XCTUnwrap(store.visual(slicer))).onSlicerChange(state)
        await Smoke.settle(store)
    }

    /// The format write the Format pane makes for a slicer's style.
    private func style(_ store: DocumentStore, _ slicer: UUID, _ style: String) {
        store.updateVisual(slicer, invalidates: .layout) { $0.setFmt("slicer", "style", .string(style)) }
    }

    func testListAndDropdownSlicersFilterTheOtherVisuals() async throws {
        let (store, facts) = await samplePage()
        let card = Smoke.addVisual(.card, [(.values, sales)], to: store)
        let columns = Smoke.addVisual(.clusteredColumn, [(.category, category), (.values, sales)], to: store)
        let slicer = Smoke.addVisual(.slicer, [(.field, segment)], to: store)
        await Smoke.settle(store)
        XCTAssertEqual(Set(store.visualData[slicer]?.table.columns.first?.values.map(\.asString) ?? []),
                       ["Consumer", "Small Business", "Enterprise", "Education"])

        // A list slicer (the default style).
        try await slice(store, slicer) { $0.selected = [.string("Enterprise")] }
        XCTAssertEqual(store.undoName, "Change Slicer")
        XCTAssertEqual(Smoke.card(store, card), facts.total { $0.segment == "Enterprise" }, accuracy: 0.01)
        assertSameSeries(Smoke.series(store, columns, labels: .category), facts.totals(by: \.category) { $0.segment == "Enterprise" }, "columns")
        // The slicer keeps listing every segment: it does not filter itself.
        XCTAssertEqual(store.visualData[slicer]?.table.rowCount, 4)

        // The same slicer as a drop-down, with two values picked; it still draws.
        style(store, slicer, "dropdown")
        try await slice(store, slicer) { $0.selected = [.string("Consumer"), .string("Education")] }
        let consumerOrEducation: (SampleFacts.Row) -> Bool = { $0.segment == "Consumer" || $0.segment == "Education" }
        XCTAssertEqual(Smoke.card(store, card), facts.total(where: consumerOrEducation), accuracy: 0.01)
        let spec = try XCTUnwrap(store.visual(slicer))
        let drawn = await Smoke.bitmap(VisualView(spec: spec, data: store.visualData[slicer] ?? VisualData(), context: store.context(for: spec)),
                                       size: CGSize(width: spec.frame.width, height: spec.frame.height))
        XCTAssertGreaterThan(drawn.map { Smoke.ink($0).share } ?? 0, 0.004, "the drop-down slicer draws nothing")

        // Its interaction with the card set to None: the card shows everything.
        store.updatePage(name: "Edit Interactions", invalidates: .visuals(nil)) { p in p.interactions[slicer] = [card: InteractionMode.none] }
        await Smoke.settle(store)
        XCTAssertEqual(Smoke.card(store, card), facts.total(), accuracy: 0.01)
        assertSameSeries(Smoke.series(store, columns, labels: .category), facts.totals(by: \.category, where: consumerOrEducation), "columns")

        // Optimize ▸ Clear slicer selections.
        AppCommands.run("optimize.clearSlicers", store)
        await Smoke.settle(store)
        XCTAssertNil(store.visual(slicer)?.slicerState)
        assertSameSeries(Smoke.series(store, columns, labels: .category), facts.totals(by: \.category), "columns after clearing")
    }

    func testBetweenAndRelativeDateSlicers() async throws {
        let (store, facts) = await samplePage()
        let card = Smoke.addVisual(.card, [(.values, sales)], to: store)
        let dates = Smoke.addVisual(.slicer, [(.field, day)], to: store)
        let prices = Smoke.addVisual(.slicer, [(.field, unitPrice)], to: store)
        await Smoke.settle(store)
        XCTAssertEqual(store.visualData[dates]?.table.rowCount, 1096)

        // Between two dates (inclusive): the whole of 2025.
        style(store, dates, "between")
        try await slice(store, dates) {
            $0.rangeLow = .date(SampleFacts.day(2025, 1, 1)); $0.rangeHigh = .date(SampleFacts.day(2025, 12, 31))
        }
        XCTAssertEqual(Smoke.card(store, card), facts.total { SampleFacts.year($0.date) == 2025 }, accuracy: 0.01)

        // And a price range on top of it: the two slicers combine.
        style(store, prices, "between")
        try await slice(store, prices) { $0.rangeLow = .double(100); $0.rangeHigh = .double(500) }
        XCTAssertEqual(Smoke.card(store, card),
                       facts.total { SampleFacts.year($0.date) == 2025 && (100...500).contains($0.unitPrice) }, accuracy: 0.01)
        try await slice(store, prices) { _ in }
        XCTAssertNil(store.visual(prices)?.slicerState, "an empty state clears the slicer")

        // Relative date: the last 3 calendar months before June 2026 are March, April and May.
        style(store, dates, "relativeDate")
        try await slice(store, dates) { s in
            var r = RelativeDateFilter(); r.direction = .last; r.count = 3; r.unit = .calendarMonths
            s.relative = r
        }
        let from = SampleFacts.day(2026, 3, 1), to = SampleFacts.day(2026, 6, 1)
        let spring = facts.total { $0.date >= from && $0.date < to }
        XCTAssertGreaterThan(spring, 0)
        XCTAssertEqual(Smoke.card(store, card), spring, accuracy: 0.01)
        // Last 7 days including today: 9 to 15 June.
        try await slice(store, dates) { s in var r = RelativeDateFilter(); r.count = 7; s.relative = r }
        let week = facts.total { $0.date >= SampleFacts.day(2026, 6, 9) && $0.date < SampleFacts.day(2026, 6, 16) }
        XCTAssertEqual(Smoke.card(store, card), week, accuracy: 0.01)
    }

    func testHierarchyInputAndButtonSlicers() async throws {
        let (store, facts) = await samplePage()
        let card = Smoke.addVisual(.card, [(.values, sales)], to: store)
        // A hierarchy slicer: Category over Subcategory, with all of Audio and only Laptops ticked.
        let tree = Smoke.addVisual(.slicer, [(.field, category), (.field, subcategory)], to: store)
        await Smoke.settle(store)
        try await slice(store, tree) { $0.hierarchyPaths = [[.string("Audio")], [.string("Computing"), .string("Laptops")]] }
        XCTAssertEqual(Smoke.card(store, card), facts.total { $0.category == "Audio" || $0.subcategory == "Laptops" }, accuracy: 0.01,
                       "a hierarchy slicer filters by its ticked paths")
        try await slice(store, tree) { _ in }

        // An input slicer with its default operator, contains: “busi” finds Small Business.
        let input = Smoke.addVisual(.inputSlicer, [(.field, segment)], to: store)
        await Smoke.settle(store)
        try await slice(store, input) { $0.selected = [.string("busi")]; $0.text = "busi" }
        XCTAssertEqual(Smoke.card(store, card), facts.total { $0.segment == "Small Business" }, accuracy: 0.01,
                       "an input slicer matches with its operator")
        // Two terms: either one matches.
        try await slice(store, input) { $0.selected = [.string("busi"), .string("educ")]; $0.text = "busi\neduc" }
        XCTAssertEqual(Smoke.card(store, card), facts.total { $0.segment == "Small Business" || $0.segment == "Education" }, accuracy: 0.01)
        // Every segment contains an “e”…
        try await slice(store, input) { $0.selected = [.string("e")]; $0.text = "e" }
        XCTAssertEqual(Smoke.card(store, card), facts.total(), accuracy: 0.01)
        // …but only two start with one. The operator is a setting the slicer writes through
        // `onSpecChange`, and the other visuals follow it at once.
        var spec = try XCTUnwrap(store.visual(input))
        spec.setFmt("slicer", "operator", .string("startsWith"))
        store.context(for: spec).onSpecChange(spec)
        await Smoke.settle(store)
        XCTAssertEqual(Smoke.card(store, card), facts.total { $0.segment == "Enterprise" || $0.segment == "Education" }, accuracy: 0.01,
                       "changing a slicer's operator requeries the visuals it filters")
        try await slice(store, input) { _ in }

        // A button slicer.
        let buttons = Smoke.addVisual(.buttonSlicer, [(.field, country)], to: store)
        await Smoke.settle(store)
        XCTAssertEqual(store.visualData[buttons]?.table.rowCount, 13)
        try await slice(store, buttons) { $0.selected = [.string("Zimbabwe"), .string("Kenya")] }
        XCTAssertEqual(Smoke.card(store, card), facts.total { $0.country == "Zimbabwe" || $0.country == "Kenya" }, accuracy: 0.01)
    }

    // MARK: Key influencers

    func testKeyInfluencersAnalyseTheRowsTheSlicersLeave() async throws {
        let (store, facts) = await samplePage()
        let ki = Smoke.addVisual(.keyInfluencers, [(.analyze, .column("Sales", "Amount")), (.explainBy, segment), (.explainBy, country)], to: store)
        let slicer = Smoke.addVisual(.slicer, [(.field, category)], to: store)
        await Smoke.settle(store)
        func analysed() async throws -> DataTable {
            let spec = try XCTUnwrap(store.visual(ki))
            let request = store.request(for: spec, on: store.currentPage)
            return try await store.withEngine { engine in Result { try engine.rows(of: "Sales", request: request) } }.get()
        }
        func drawing() async throws -> NSBitmapImageRep {
            let spec = try XCTUnwrap(store.visual(ki))
            let view = VisualView(spec: spec, data: store.visualData[ki] ?? VisualData(), context: store.context(for: spec, interactive: false))
            return try await XCTUnwrapAsync(await Smoke.bitmap(view, size: CGSize(width: 520, height: 360), patience: 6))
        }
        let everything = try await analysed()
        XCTAssertEqual(everything.rowCount, facts.rows.count)
        let before = try await drawing()

        try await slice(store, slicer) { $0.selected = [.string("Audio")] }
        let audio = try await analysed()
        XCTAssertEqual(audio.rowCount, facts.rows.filter { $0.category == "Audio" }.count, "the analysis keeps only the sliced rows")
        let amount = try XCTUnwrap(audio.columnIndex("Amount"))
        XCTAssertEqual((0..<audio.rowCount).reduce(0.0) { $0 + (audio[$1, amount].asDouble ?? 0) }, facts.total { $0.category == "Audio" }, accuracy: 0.01)
        let after = try await drawing()
        XCTAssertGreaterThan(Smoke.difference(before, after), 0.004, "slicing the page does not change the analysis")
    }

    // MARK: Drill

    func testDrillDownUpAndExpandAllOnAHierarchy() async throws {
        let (store, facts) = await samplePage()
        let bars = Smoke.addVisual(.clusteredBar, [(.category, category), (.category, subcategory), (.category, product), (.values, sales)], to: store)
        let card = Smoke.addVisual(.card, [(.values, sales)], to: store)
        await Smoke.settle(store)
        store.selection = [bars]
        assertSameSeries(Smoke.series(store, bars, labels: .category), facts.totals(by: \.category), "top level")
        XCTAssertFalse(AppCommands.command("drill.up")?.isEnabled(store) ?? true)

        // Go to the next level: every subcategory.
        AppCommands.run("drill.nextLevel", store)
        await Smoke.settle(store)
        assertSameSeries(Smoke.series(store, bars, labels: .category), facts.totals(by: \.subcategory), "next level")
        XCTAssertEqual(store.undoName, "Drill Down")
        AppCommands.run("drill.up", store)
        await Smoke.settle(store)
        assertSameSeries(Smoke.series(store, bars, labels: .category), facts.totals(by: \.category), "back up")

        // Select Audio first (it filters the card), then drill into it, as a double-click does.
        let audio = Smoke.point(store, bars, category: "Audio")
        let context = store.context(for: try XCTUnwrap(store.visual(bars)))
        context.onSelect([audio], false)
        await Smoke.settle(store)
        XCTAssertEqual(Smoke.card(store, card), facts.total { $0.category == "Audio" }, accuracy: 0.01)
        context.onDrill(.down(audio))
        await Smoke.settle(store)
        assertSameSeries(Smoke.series(store, bars, labels: .category), facts.totals(by: \.subcategory) { $0.category == "Audio" }, "Audio")
        XCTAssertTrue(store.context(for: try XCTUnwrap(store.visual(bars))).selection.isEmpty, "drilling clears the visual's selection")
        XCTAssertEqual(Smoke.card(store, card), facts.total(), accuracy: 0.01, "drilling does not filter other visuals, so the card shows all")

        // Down again into Headphones: its three products.
        let headphones = Smoke.point(store, bars, category: "Headphones")
        store.context(for: try XCTUnwrap(store.visual(bars))).onDrill(.down(headphones))
        await Smoke.settle(store)
        assertSameSeries(Smoke.series(store, bars, labels: .category), facts.totals(by: \.product) { $0.subcategory == "Headphones" }, "Headphones")
        XCTAssertFalse(AppCommands.command("drill.nextLevel")?.isEnabled(store) ?? true, "there is no level below Product")

        // Up twice: Audio's subcategories, then the categories.
        AppCommands.run("drill.up", store)
        await Smoke.settle(store)
        assertSameSeries(Smoke.series(store, bars, labels: .category), facts.totals(by: \.subcategory) { $0.category == "Audio" }, "up to Audio")
        AppCommands.run("drill.up", store)
        await Smoke.settle(store)
        assertSameSeries(Smoke.series(store, bars, labels: .category), facts.totals(by: \.category), "up to the top")

        // Expand all down one level: category and subcategory side by side.
        AppCommands.run("drill.expand", store)
        await Smoke.settle(store)
        let data = try XCTUnwrap(store.visualData[bars])
        XCTAssertEqual(data.indices(.category).count, 2)
        var pairs: [String: Double] = [:]
        for r in 0..<data.table.rowCount {
            pairs["\(data.table[r, 0].asString)/\(data.table[r, 1].asString)"] = data.table[r, 2].asDouble
        }
        assertSameSeries(pairs, facts.totals(by: { "\($0.category)/\($0.subcategory)" }), "expanded")
        XCTAssertTrue(store.visual(bars)?.expandedAllLevels ?? false)
        AppCommands.run("drill.up", store)
        await Smoke.settle(store)
        XCTAssertEqual(store.visual(bars)?.expandedAllLevels, false)
        assertSameSeries(Smoke.series(store, bars, labels: .category), facts.totals(by: \.category), "collapsed again")
    }

    // MARK: Filters pane

    func testTopNAndRelativeDateFiltersFromTheFiltersPane() async throws {
        let (store, facts) = await samplePage()
        let table = Smoke.addVisual(.table, [(.values, product), (.values, sales)], to: store)
        await Smoke.settle(store)
        XCTAssertEqual(store.visualData[table]?.table.rowCount, 24)

        // Data pane ▸ field menu ▸ Add filter ▸ On this visual; then Top N in the Filters pane.
        store.selection = [table]
        store.addFilter(product, scope: .visual, announce: true)
        XCTAssertEqual(store.undoName, "Add Visual Filter")
        let id = try XCTUnwrap(store.visual(table)?.filters.first?.id)
        store.updateFilter(id: id, scope: .visual, name: "Change Filter Type") { FilterEditing.setKind(.topN, of: &$0) }
        store.updateFilter(id: id, scope: .visual, name: "Change Filter") { $0.topN.count = 5 }
        // The By value well offers the model's measures; Total Sales is one of them.
        let by = try XCTUnwrap(FilterEditing.topNCandidates(store.model).first { $0.kind == .measure && $0.name == "Total Sales" })
        store.updateFilter(id: id, scope: .visual, name: "Change Filter") { FilterEditing.setTopNBy(by, of: &$0) }
        await Smoke.settle(store)
        let byProduct = facts.totals(by: \.product)
        let ranked = byProduct.sorted { $0.value > $1.value }
        assertSameSeries(Smoke.rows(store, table), Dictionary(uniqueKeysWithValues: ranked.prefix(5).map { ($0.key, $0.value) }), "top 5")
        // Bottom 3.
        store.updateFilter(id: id, scope: .visual, name: "Change Filter") { $0.topN.isBottom = true; $0.topN.count = 3 }
        await Smoke.settle(store)
        assertSameSeries(Smoke.rows(store, table), Dictionary(uniqueKeysWithValues: ranked.suffix(3).map { ($0.key, $0.value) }), "bottom 3")

        // A page filter on the order date, turned into a relative date filter: the last 7 days.
        store.addFilter(orderDate, scope: .page, announce: true)
        let pageFilter = try XCTUnwrap(store.currentPage.filters.first?.id)
        store.updateFilter(id: pageFilter, scope: .page, name: "Change Filter Type") { FilterEditing.setKind(.relativeDate, of: &$0) }
        store.updateFilter(id: id, scope: .visual, name: "Change Filter") { f in f.kind = .basic; f.values = [] }
        await Smoke.settle(store)
        let lastWeek: (SampleFacts.Row) -> Bool = { $0.date >= SampleFacts.day(2026, 6, 9) && $0.date < SampleFacts.day(2026, 6, 16) }
        assertSameSeries(Smoke.rows(store, table), facts.totals(by: \.product, where: lastWeek), "last 7 days")
        // Last 2 calendar years: 2024 and 2025.
        store.updateFilter(id: pageFilter, scope: .page) { $0.relative.unit = .calendarYears; $0.relative.count = 2 }
        await Smoke.settle(store)
        assertSameSeries(Smoke.rows(store, table), facts.totals(by: \.product) { SampleFacts.year($0.date) < 2026 }, "2024–2025")
        // Removing the filter brings every row back.
        store.removeFilter(id: pageFilter, scope: .page)
        await Smoke.settle(store)
        assertSameSeries(Smoke.rows(store, table), byProduct, "no filter")
    }
}
