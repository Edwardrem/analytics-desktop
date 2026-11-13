import XCTest
import FacetCore
@testable import FacetVisuals

/// The chart format catalog against the renderers. Expected defaults are the fallback literals at
/// each renderer's format read (file and line noted per assertion), not catalog output.
final class ChartFormatCatalogTests: XCTestCase {
    private func property(_ type: VisualType, _ card: String, _ key: String) -> FormatProperty? {
        ChartFormatCatalog.properties(for: type).first { $0.card == card && $0.key == key }
    }

    func testEveryChartTypeHasProperties() {
        for type in ChartVisuals.supportedTypes {
            XCTAssertFalse(ChartFormatCatalog.properties(for: type).isEmpty, "\(type.rawValue) has no format properties")
        }
        XCTAssertTrue(ChartFormatCatalog.properties(for: .table).isEmpty, "tables belong to the component catalog")
    }

    func testIdsAreUniqueAndEntriesAreComplete() {
        for type in ChartVisuals.supportedTypes {
            let all = ChartFormatCatalog.properties(for: type)
            XCTAssertEqual(all.count, Set(all.map(\.id)).count, "\(type.rawValue) lists a key twice")
            for p in all {
                XCTAssertFalse(p.label.isEmpty || p.cardLabel.isEmpty, "\(type.rawValue) \(p.id) lacks a label")
                if case .options(let o) = p.kind {
                    XCTAssertFalse(o.isEmpty, "\(type.rawValue) \(p.id) has no options")
                    if let d = p.defaultValue.stringValue { XCTAssertTrue(o.contains(d), "\(type.rawValue) \(p.id) default is not an option") }
                }
                if p.kind == .number {
                    XCTAssertNotNil(p.range, "\(type.rawValue) \(p.id) declares no range")
                    if let d = p.defaultValue.doubleValue, let r = p.range { XCTAssertTrue(r.contains(d), "\(type.rawValue) \(p.id) default is out of range") }
                }
                if p.kind == .field { XCTAssertEqual(p.defaultValue, .null, "\(type.rawValue) \(p.id): no field is chosen by default") }
                if p.kind == .color { XCTAssertNotNil(p.themeColor, "\(type.rawValue) \(p.id) names no theme colour") }
                if p.kind == .bool, p.defaultValue == .null { XCTAssertNotNil(p.automatic, "\(type.rawValue) \(p.id) is automatic without a rule") }
            }
        }
    }

    func testDefaultsMatchTheRendererFallbacks() {
        // PieChart.swift:106 — innerRadius falls back to 64 for a donut, 0 for a pie.
        XCTAssertEqual(property(.donut, "slices", "innerRadius")?.defaultValue, .number(64))
        XCTAssertEqual(property(.pie, "slices", "innerRadius")?.defaultValue, .number(0))
        // FlowTreemap.swift:160 — the sunburst hole falls back to 30.
        XCTAssertEqual(property(.sunburst, "slices", "innerRadius")?.defaultValue, .number(30))
        // Data labels are on by default for pie (PieChart.swift:108), waterfall (WaterfallChart.swift:159),
        // funnel (FlowFunnelRadar.swift:123) and treemap (FlowTreemap.swift:104); off for cartesian
        // charts (CartesianLayout.swift:87) and the histogram (StatHistogram.swift, drawLabels guard).
        for type in [VisualType.pie, .waterfall, .funnel, .treemap, .sunburst] {
            XCTAssertEqual(property(type, "dataLabels", "show")?.defaultValue, .bool(true), type.rawValue)
        }
        for type in [VisualType.clusteredColumn, .line, .histogram, .boxPlot] {
            XCTAssertEqual(property(type, "dataLabels", "show")?.defaultValue, .bool(false), type.rawValue)
        }
        // Corner radii: cartesian bars 2.5 (CartesianLayout.swift:60), histogram 2 (StatHistogram.swift, radius).
        XCTAssertEqual(property(.clusteredBar, "bars", "cornerRadius")?.defaultValue, .number(2.5))
        XCTAssertEqual(property(.histogram, "bars", "cornerRadius")?.defaultValue, .number(2))
        // Inner padding: 26% clustered / 34% stacked (CartesianLayout.swift:58), 30% waterfall (WaterfallChart.swift:118).
        XCTAssertEqual(property(.clusteredColumn, "bars", "innerPadding")?.defaultValue, .number(26))
        XCTAssertEqual(property(.stackedColumn, "bars", "innerPadding")?.defaultValue, .number(34))
        XCTAssertEqual(property(.waterfall, "bars", "innerPadding")?.defaultValue, .number(30))
        // Marker size: 9 on a dot plot, 5 on lines (CartesianLayout.swift:65).
        XCTAssertEqual(property(.dotPlot, "lines", "markerSize")?.defaultValue, .number(9))
        XCTAssertEqual(property(.line, "lines", "markerSize")?.defaultValue, .number(5))
        // Radar markers default on (FlowFunnelRadar.swift:237); cartesian line markers off (CartesianLayout.swift:64).
        XCTAssertEqual(property(.radar, "lines", "showMarkers")?.defaultValue, .bool(true))
        XCTAssertEqual(property(.line, "lines", "showMarkers")?.defaultValue, .bool(false))
    }

    func testWordCloudAndScatterDefaultsKeepTheirOriginalLook() {
        // Word sizes ran from 10 to 44 pt with no word limit; scatter points had radius 3.5 at 80% opacity.
        XCTAssertEqual(property(.wordCloud, "wordCloud", "minFontSize")?.defaultValue, .number(10))
        XCTAssertEqual(property(.wordCloud, "wordCloud", "maxFontSize")?.defaultValue, .number(44))
        XCTAssertEqual(property(.wordCloud, "wordCloud", "maxWords")?.defaultValue, .number(0))
        XCTAssertEqual(property(.scatter, "markers", "size")?.defaultValue, .number(3.5))
        XCTAssertEqual(property(.scatter, "markers", "transparency")?.defaultValue, .number(20))
    }

    func testDetailFieldIsACartesianDataLabelOption() {
        // CartesianOverlay.labelText reads dataLabels.detailField; no other chart does.
        XCTAssertEqual(property(.clusteredColumn, "dataLabels", "detailField")?.kind, .field)
        XCTAssertEqual(property(.line, "dataLabels", "detailField")?.kind, .field)
        XCTAssertNil(property(.pie, "dataLabels", "detailField"))
        XCTAssertNil(property(.histogram, "dataLabels", "detailField"))
    }

    func testLegendDefaultFollowsEachScaffold() {
        // PieChart.swift:83 passes defaultShow false, WaterfallChart.swift:99 true; the others leave
        // it to the item count (ChartChrome.swift, ChartScaffold.init).
        XCTAssertEqual(property(.pie, "legend", "show")?.defaultValue, .bool(false))
        XCTAssertEqual(property(.waterfall, "legend", "show")?.defaultValue, .bool(true))
        let column = property(.clusteredColumn, "legend", "show")
        XCTAssertEqual(column?.defaultValue, .null)
        XCTAssertEqual(column?.automatic, .multipleSeries)
        // Charts without a scaffold have no legend card.
        for type in [VisualType.funnel, .treemap, .scatter, .candlestick, .heatmap] {
            XCTAssertNil(property(type, "legend", "show"), type.rawValue)
        }
    }

    func testColourDefaultsNameTheRendererThemeColours() {
        // StatSupport.swift, StatColorScale: theme minimum / maximum / center.
        XCTAssertEqual(property(.heatmap, "heatmap", "minColor")?.themeColor, .minimum)
        XCTAssertEqual(property(.heatmap, "heatmap", "maxColor")?.themeColor, .maximum)
        XCTAssertEqual(property(.calendarHeatmap, "heatmap", "midColor")?.themeColor, .center)
        // StatExtras.swift: bullet track = gridline, bar = accent; candles good / bad.
        XCTAssertEqual(property(.bullet, "bullet", "trackColor")?.themeColor, .gridline)
        XCTAssertEqual(property(.bullet, "bullet", "barColor")?.themeColor, .accent)
        XCTAssertEqual(property(.candlestick, "candlestick", "upColor")?.themeColor, .good)
        XCTAssertEqual(property(.candlestick, "candlestick", "downColor")?.themeColor, .bad)
        // WaterfallChart.swift:87–89.
        XCTAssertEqual(property(.waterfall, "waterfall", "totalColor")?.themeColor, .firstDataColor)
        var theme = ThemeSpec.facet
        theme.minimum = "#112233"; theme.dataColors = ["#ABCDEF", "#000000"]
        XCTAssertEqual(FormatProperty.ThemeColor.minimum.hex(in: theme), "#112233")
        XCTAssertEqual(FormatProperty.ThemeColor.firstDataColor.hex(in: theme), "#ABCDEF")
    }

    func testAxisCardsFollowOrientation() {
        // CartesianOptions: horizontal charts read the category axis from yAxis, the value axis from xAxis.
        XCTAssertNotNil(property(.clusteredBar, "yAxis", "labelRotation"))
        XCTAssertNotNil(property(.clusteredBar, "xAxis", "logScale"))
        XCTAssertNotNil(property(.clusteredColumn, "xAxis", "labelRotation"))
        XCTAssertNotNil(property(.clusteredColumn, "yAxis", "logScale"))
        // A 100% axis is never logarithmic (CartesianLayout.swift:72).
        XCTAssertNil(property(.stackedColumn100, "yAxis", "logScale"))
        // Only combos have a secondary axis.
        XCTAssertNotNil(property(.lineClusteredColumn, "y2Axis", "show"))
        XCTAssertNil(property(.clusteredColumn, "y2Axis", "show"))
        // Scatter draws through StatPlot, which reads both axis cards.
        XCTAssertNotNil(property(.scatter, "yAxis", "min"))
        XCTAssertNotNil(property(.scatter, "xAxis", "showTitle"))
    }

    // MARK: - Effective values

    func testValueResolvesLikeTheRenderer() {
        guard let radius = property(.clusteredColumn, "bars", "cornerRadius") else { return XCTFail("no bars.cornerRadius") }
        var spec = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 300, height: 200))
        var theme = ThemeSpec.facet
        // Nothing set: the declared default.
        XCTAssertEqual(radius.value(in: ResolvedFormat(spec: spec, theme: theme)), .number(2.5))
        // Theme "*" defaults beat the declared default; the type's defaults beat "*"; the visual beats both.
        theme.visualDefaults["*"] = ["bars": ["cornerRadius": .number(6)]]
        XCTAssertEqual(radius.value(in: ResolvedFormat(spec: spec, theme: theme)), .number(6))
        theme.visualDefaults["clusteredColumn"] = ["bars": ["cornerRadius": .number(8)]]
        XCTAssertEqual(radius.value(in: ResolvedFormat(spec: spec, theme: theme)), .number(8))
        spec.setFmt("bars", "cornerRadius", .number(1))
        XCTAssertEqual(radius.value(in: ResolvedFormat(spec: spec, theme: theme)), .number(1))
    }

    func testAutomaticBoolsShowWhatTheRendererDoes() {
        guard let legend = property(.clusteredColumn, "legend", "show"),
              let patterns = property(.clusteredColumn, "accessibility", "patterns") else { return XCTFail("missing entries") }
        var spec = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 300, height: 200))
        var theme = ThemeSpec.facet
        // One value field, no legend field: one series, so no legend.
        spec.wells[Well.values.rawValue] = [.measure("Sales", "Amount")]
        XCTAssertFalse(legend.isOn(in: ResolvedFormat(spec: spec, theme: theme)))
        // Two value fields, or a legend field: several series, so the legend shows.
        spec.wells[Well.values.rawValue] = [.measure("Sales", "Amount"), .measure("Sales", "Cost")]
        XCTAssertTrue(legend.isOn(in: ResolvedFormat(spec: spec, theme: theme)))
        spec.wells[Well.values.rawValue] = [.measure("Sales", "Amount")]
        spec.wells[Well.legend.rawValue] = [.column("Sales", "Region")]
        XCTAssertTrue(legend.isOn(in: ResolvedFormat(spec: spec, theme: theme)))
        // An explicit value always wins.
        spec.setFmt("legend", "show", .bool(false))
        XCTAssertFalse(legend.isOn(in: ResolvedFormat(spec: spec, theme: theme)))
        // Patterns follow the theme's high-contrast flag (ChartChrome.swift, usesPatterns).
        XCTAssertFalse(patterns.isOn(in: ResolvedFormat(spec: spec, theme: theme)))
        theme.isHighContrast = true
        XCTAssertTrue(patterns.isOn(in: ResolvedFormat(spec: spec, theme: theme)))
    }

    // MARK: - Safe numbers

    func testFormatNumberClampsAndRejectsNonFinite() {
        XCTAssertEqual(FormatNumber.int(1e19, in: 0...200), 200)
        XCTAssertEqual(FormatNumber.int(-1e19, in: 0...200), 0)
        XCTAssertEqual(FormatNumber.int(7.9, in: 0...200), 7)
        XCTAssertNil(FormatNumber.int(.infinity, in: 0...200))
        XCTAssertNil(FormatNumber.int(.nan, in: 0...200))
        XCTAssertNil(FormatNumber.int(nil, in: 0...200))
        XCTAssertEqual(FormatNumber.clamped(150, to: 0...100), 100)
        XCTAssertEqual(FormatNumber.clamped(-3, to: 0...100), 0)
        XCTAssertNil(FormatNumber.clamped(.nan, to: 0...100))
    }

    func testRenderersSurviveExtremeFormatNumbers() {
        // A document can carry any number. 1e19 used to trap in Int(_:), 1e9 bins used to stall.
        let values: [Value] = (1...50).map { .double(Double($0)) }
        let data = VisualData(table: DataTable(name: "t", columns: [DataColumn(name: "v", type: .decimal, values: values)]),
                              roles: [Well.values.rawValue: [0]], fields: [.measure("Sales", "v")], formats: [""])
        var spec = VisualSpec(type: .histogram, frame: Frame(x: 0, y: 0, width: 400, height: 300))
        spec.wells[Well.values.rawValue] = [.measure("Sales", "v")]
        for bins in [1e19, 1e9, -1e19, Double.infinity, Double.nan] {
            spec.setFmt("histogram", "bins", .number(bins))
            let model = HistogramModel(spec: spec, data: data, style: ChartStyle(spec: spec, theme: .facet))
            XCTAssertLessThanOrEqual(model.edges.count - 1, HistogramModel.maxBins, "bins = \(bins)")
            XCTAssertGreaterThanOrEqual(model.edges.count - 1, 1, "bins = \(bins)")
        }
        // 1…50 in 5 fixed bins: edges 1, 10.8, 20.6, 30.4, 40.2, 50.
        spec.setFmt("histogram", "bins", .number(5))
        let five = HistogramModel(spec: spec, data: data, style: ChartStyle(spec: spec, theme: .facet))
        XCTAssertEqual(five.edges.count, 6)
        XCTAssertEqual(five.edges.first ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(five.edges.last ?? 0, 50, accuracy: 1e-9)

        let f = ResolvedFormat(spec: { var s = spec; s.setFmt("yAxis", "decimals", .number(1e19)); s.setFmt("xAxis", "decimals", .number(-4)); return s }(),
                               theme: .facet)
        XCTAssertEqual(f.decimals("yAxis"), 10)
        XCTAssertEqual(f.decimals("xAxis"), 0)
        XCTAssertNil(f.decimals("dataLabels"))
        XCTAssertEqual(f.int("waterfall", "maxBreakdowns", 5, in: 1...100), 5)
    }

    func testDefaultBoundsCoverComponentNumbers() {
        XCTAssertEqual(FormatNumber.defaultBounds(key: "decimals"), 0...10)
        XCTAssertEqual(FormatNumber.defaultBounds(key: "transparency"), 0...100)
        XCTAssertEqual(FormatNumber.defaultBounds(key: "columns"), 0...100)
        XCTAssertEqual(FormatNumber.defaultBounds(key: "fontSize"), 1...400)
        XCTAssertEqual(FormatNumber.defaultBounds(key: "rowPadding"), 0...4_000)
        // Every component number property ends up with finite bounds Int(_:) can take.
        for type in ComponentVisuals.supportedTypes {
            for p in ComponentFormatCatalog.properties(for: type).map(FormatProperty.init) where p.kind == .number {
                XCTAssertTrue(p.bounds.lowerBound.isFinite && p.bounds.upperBound.isFinite && abs(p.bounds.upperBound) <= 1e15, p.id)
                if let d = p.defaultValue.doubleValue { XCTAssertTrue(p.bounds.contains(d), "\(type.rawValue) \(p.id) default \(d) is outside \(p.bounds)") }
            }
        }
    }
}
