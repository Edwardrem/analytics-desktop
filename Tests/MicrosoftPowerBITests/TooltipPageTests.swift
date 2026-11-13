import XCTest
import FacetCore
import FacetVisuals
@testable import MicrosoftPowerBI

/// Report page tooltips (binding, automatic matching by tooltip fields, how the page is filtered) and
/// the modern tooltip's drill actions.
@MainActor
final class TooltipPageTests: XCTestCase {
    private typealias F = ReportFixture

    private func tooltipPage(_ name: String, fields: [FieldRef]? = nil) -> Page {
        var p = Page(name: name)
        p.isTooltipPage = true
        p.size = .tooltip
        p.tooltipFields = fields
        return p
    }

    func testExplicitPageWinsThenTooltipFieldsThenDefault() {
        var report = Report()
        let byRegion = tooltipPage("By region", fields: [F.region]), plain = tooltipPage("Plain")
        var notATooltip = Page(name: "Normal"); notATooltip.tooltipFields = [F.region]
        report.pages = [Page(name: "Main"), notATooltip, plain, byRegion]
        var chart = F.chart()
        // Automatic: the chart uses Region, and "By region" is the tooltip page for Region.
        XCTAssertEqual(TooltipPages.page(for: chart, in: report)?.name, "By region")
        // A chart with none of the tooltip fields keeps the default tooltip.
        XCTAssertNil(TooltipPages.page(for: F.chart(category: F.product).with { $0.setFields(.values, [F.total]) }, in: report))
        // Naming a page overrides the automatic match.
        chart.tooltipPageID = plain.id
        XCTAssertEqual(TooltipPages.page(for: chart, in: report)?.name, "Plain")
        // A named page that is gone, or no longer a tooltip page, falls back to the default tooltip.
        chart.tooltipPageID = notATooltip.id
        XCTAssertNil(TooltipPages.page(for: chart, in: report))
        chart.tooltipPageID = UUID()
        XCTAssertNil(TooltipPages.page(for: chart, in: report))
    }

    func testTooltipPageIsFilteredToTheHoveredPointAndTheSourceContext() {
        let engine = F.engine()
        let card = F.card()
        XCTAssertEqual(F.number(engine.visualData(spec: card, request: VisualRequest())), 150)
        // Hovering North: 10 + 20.
        var request = TooltipPages.request(base: VisualRequest(), source: VisualRequest(), point: F.point(F.region, "North"))
        XCTAssertEqual(F.number(engine.visualData(spec: card, request: request)), 30)
        // The hovered visual was itself filtered to Web, so the tooltip shows North ∩ Web = 10.
        var source = VisualRequest()
        source.filters = [Drillthrough.basic(F.channel, [.string("Web")])]
        request = TooltipPages.request(base: VisualRequest(), source: source, point: F.point(F.region, "North"))
        XCTAssertEqual(F.number(engine.visualData(spec: card, request: request)), 10)
        // A filter on the tooltip page itself also applies: Apple only → North ∩ Web ∩ Apple = 10, South ∩ Web ∩ Apple = 30.
        var base = VisualRequest()
        base.filters = [Drillthrough.basic(F.product, [.string("Apple")])]
        request = TooltipPages.request(base: base, source: source, point: F.point(F.region, "South"))
        XCTAssertEqual(F.number(engine.visualData(spec: card, request: request)), 30)
        // Tooltip pages never show cross-highlight baselines.
        source.highlights = [[F.point(F.product, "Pear")]]
        XCTAssertTrue(TooltipPages.request(base: base, source: source, point: F.point(F.region, "South")).highlights.isEmpty)
    }

    func testLargePagesAreScaledDownButSmallOnesAreNotEnlarged() {
        XCTAssertEqual(TooltipPages.scale(for: .tooltip), 1)                      // 320 wide
        XCTAssertEqual(TooltipPages.scale(for: PageSize(width: 800, height: 600)), 0.5)
    }

    func testStoreOffersThePageTooltipOnlyToBoundVisuals() {
        let store = F.store()
        let chart = store.addVisual(.clusteredColumn) { $0.setFields(.category, [F.region]); $0.setFields(.values, [F.amount]) }
        guard let before = store.visual(chart) else { return XCTFail("chart missing") }
        XCTAssertNil(store.context(for: before).pageTooltip)
        let main = store.currentPageID
        AppCommands.run("insert.tooltipPage", store)
        XCTAssertTrue(store.currentPage.isTooltipPage)
        XCTAssertEqual(store.currentPage.size, .tooltip)
        let tip = store.currentPageID
        store.goToPage(main)
        store.updateVisual(chart) { $0.tooltipPageID = tip }
        guard let bound = store.visual(chart) else { return XCTFail("chart missing") }
        XCTAssertNotNil(store.context(for: bound).pageTooltip)
        XCTAssertNil(store.context(for: bound, interactive: false).pageTooltip, "exports and thumbnails have no hover")
    }

    // MARK: Modern tooltip actions

    func testTooltipFooterOffersOnlyWhatCanBeDone() {
        var chart = F.chart()
        chart.setFields(.category, [F.region, F.product])
        // Top level, on a data point, with one drillthrough page.
        XCTAssertEqual(TooltipActions.kinds(spec: chart, hasSelection: true, drillthroughTargets: 1, modern: true), [.drillDown, .drillThrough])
        // Deepest level: nothing below, one level above.
        chart.drillLevel = 1
        XCTAssertEqual(TooltipActions.kinds(spec: chart, hasSelection: true, drillthroughTargets: 0, modern: true), [.drillUp])
        // A single-level chart with no drillthrough page has no footer; neither do classic tooltips.
        XCTAssertEqual(TooltipActions.kinds(spec: F.chart(), hasSelection: true, drillthroughTargets: 0, modern: true), [])
        chart.drillLevel = 0
        XCTAssertEqual(TooltipActions.kinds(spec: chart, hasSelection: true, drillthroughTargets: 2, modern: false), [])
        // Without a data point under the pointer there is nothing to drill into or through.
        XCTAssertEqual(TooltipActions.kinds(spec: chart, hasSelection: false, drillthroughTargets: 2, modern: true), [])
    }

    func testContextCarriesReportTooltipSettingAndDrillthroughTargets() {
        let store = F.store()
        let chart = store.addVisual(.clusteredColumn) { $0.setFields(.category, [F.region]); $0.setFields(.values, [F.amount]) }
        store.addPage(named: "Details")
        store.addFilter(F.region, scope: .drillthrough)
        store.goToPage(store.report.pages[0].id)
        guard let spec = store.visual(chart) else { return XCTFail("chart missing") }
        var context = store.context(for: spec)
        XCTAssertTrue(context.modernTooltips)
        XCTAssertEqual(context.drillthroughTargets(F.point(F.region, "North")).map(\.name), ["Details"])
        XCTAssertTrue(context.drillthroughTargets(F.point(F.product, "Apple")).isEmpty)
        store.mutate("Settings", invalidates: .layout) { $0.report.settings.modernTooltips = false }
        context = store.context(for: spec)
        XCTAssertFalse(context.modernTooltips)
    }
}

private extension VisualSpec {
    func with(_ change: (inout VisualSpec) -> Void) -> VisualSpec { var copy = self; change(&copy); return copy }
}
