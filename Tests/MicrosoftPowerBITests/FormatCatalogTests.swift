import XCTest
import FacetCore
import FacetVisuals
@testable import MicrosoftPowerBI

/// Tests for the Format pane's catalog logic: cards per visual type, General-tab cards, search,
/// the override check behind per-card reset, and chart key uniqueness. Expected values come from
/// the FacetVisuals catalogs and the renderers' format reads, not from running the app.
final class FormatCatalogTests: XCTestCase {
    // MARK: - Visual-tab cards per visual type

    /// Types that yield no Visual-tab cards, with the reason each has none.
    /// - Key influencers, decomposition tree, narrative and Q&A are app-supplied through
    ///   `VisualContext.extensionView` and honour no format keys.
    /// - Script visuals render the app's script output (`spec.imageData`); paginated report, Power
    ///   Apps and metrics are embedded web views — none has format keys in the component catalog.
    ///   (Power automate does: the "Run flow" button label.)
    private static let typesWithoutVisualCards: [VisualType: String] = [
        .keyInfluencers: "app-supplied through VisualContext.extensionView and honours no format keys",
        .decompositionTree: "app-supplied through VisualContext.extensionView and honours no format keys",
        .narrative: "app-supplied through VisualContext.extensionView and honours no format keys",
        .qna: "app-supplied through VisualContext.extensionView and honours no format keys",
        .pythonVisual: "the script renders into spec.imageData; no format keys in the component catalog",
        .rVisual: "the script renders into spec.imageData; no format keys in the component catalog",
        .paginatedReport: "an embedded web view with no format keys in the component catalog",
        .powerApps: "an embedded web view with no format keys in the component catalog",
        .metrics: "an embedded web view with no format keys in the component catalog",
    ]

    func testEveryVisualTypeHasVisualCardsOrIsListedAsHavingNone() {
        for type in VisualType.allCases {
            let cards = FormatCatalog.visualCards(for: type)
            if let reason = Self.typesWithoutVisualCards[type] {
                XCTAssertTrue(cards.isEmpty,
                              "\(type.displayName) should have no Visual-tab cards — \(reason); got \(cards.map(\.card))")
            } else {
                XCTAssertFalse(cards.isEmpty, "\(type.displayName) should show at least one Visual-tab card")
            }
        }
    }

    func testVisualCardIdsAreUniquePerType() {
        for type in VisualType.allCases {
            let ids = FormatCatalog.visualCards(for: type).flatMap(\.properties).map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "\(type.displayName) has duplicate format ids")
        }
    }

    func testAllCardsAndPropertiesHaveLabels() {
        for type in VisualType.allCases {
            for card in FormatCatalog.visualCards(for: type) {
                XCTAssertFalse(card.label.isEmpty, "\(type.displayName) card \(card.card) has no label")
                for property in card.properties {
                    XCTAssertFalse(property.label.isEmpty, "\(type.displayName) \(property.id) has no label")
                    if case .options(let options) = property.kind {
                        XCTAssertFalse(options.isEmpty, "\(type.displayName) \(property.id) has no options")
                    }
                }
            }
            for card in FormatCatalog.generalCards(for: type) {
                XCTAssertFalse(card.label.isEmpty, "\(type.displayName) General card \(card.card) has no label")
                for property in card.properties {
                    XCTAssertFalse(property.label.isEmpty, "\(type.displayName) General \(property.id) has no label")
                }
            }
        }
    }

    // MARK: - Cards come from the FacetVisuals catalogs

    func testComponentCardsComeFromTheComponentCatalog() {
        // TableFamily: the columnHeaders card carries show (default true) and fontSize (theme, nil default).
        let table = FormatCatalog.visualCards(for: .table)
        let headers = table.first { $0.card == "columnHeaders" }
        XCTAssertNotNil(headers)
        XCTAssertEqual(headers?.label, "Column headers")
        XCTAssertEqual(headers?.properties.first { $0.key == "show" }?.defaultValue, .bool(true))
        XCTAssertEqual(headers?.properties.first { $0.key == "fontSize" }?.defaultValue, .null)
        // Only the table family's own types get the dataBars card; the matrix gets layout instead.
        XCTAssertNotNil(table.first { $0.card == "dataBars" })
        XCTAssertNil(table.first { $0.card == "layout" })
        let matrix = FormatCatalog.visualCards(for: .matrix)
        XCTAssertNotNil(matrix.first { $0.card == "layout" })
        XCTAssertNil(matrix.first { $0.card == "dataBars" })
        // Slicers surface the single "slicer" card.
        XCTAssertNotNil(FormatCatalog.visualCards(for: .slicer).first { $0.card == "slicer" })
        // Power automate is the one embed with a catalog entry: the "Run flow" button label.
        let automate = FormatCatalog.visualCards(for: .powerAutomate)
        XCTAssertEqual(automate.first?.card, "text")
        XCTAssertEqual(automate.first?.properties.first { $0.key == "text" }?.defaultValue, .string("Run flow"))
    }

    func testChartCardsComeFromTheChartCatalog() {
        // Cartesian charts: legend, both axis cards, the shape card, data labels and patterns.
        let column = FormatCatalog.visualCards(for: .clusteredColumn)
        for expected in ["legend", "xAxis", "yAxis", "dataLabels", "bars", "accessibility"] {
            XCTAssertNotNil(column.first { $0.card == expected }, "clusteredColumn is missing the \(expected) card")
        }
        XCTAssertEqual(column.first { $0.card == "yAxis" }?.label, "Y axis")
        // Horizontal charts read their category axis from "yAxis" and their value axis from "xAxis".
        func hasKey(_ cards: [FormatCardModel], _ card: String, _ key: String) -> Bool {
            cards.first { $0.card == card }?.properties.contains { $0.key == key } ?? false
        }
        let bar = FormatCatalog.visualCards(for: .clusteredBar)
        XCTAssertTrue(hasKey(bar, "yAxis", "labelRotation"), "horizontal charts put label rotation on the category card (yAxis)")
        XCTAssertTrue(hasKey(bar, "xAxis", "logScale"), "horizontal charts put the value scale on the value card (xAxis)")
        XCTAssertTrue(hasKey(column, "xAxis", "labelRotation"))
        XCTAssertTrue(hasKey(column, "yAxis", "logScale"))
        // Pie vs donut: only the donut gets the centre keys; both get the slices card.
        let pie = FormatCatalog.visualCards(for: .pie)
        let donut = FormatCatalog.visualCards(for: .donut)
        XCTAssertTrue(hasKey(pie, "slices", "innerRadius"))
        XCTAssertFalse(hasKey(pie, "slices", "centerValue"))
        XCTAssertTrue(hasKey(donut, "slices", "centerValue"))
        XCTAssertTrue(hasKey(donut, "slices", "centerLabel"))
        // Waterfall carries its own card with the increase/decrease colours.
        let waterfall = FormatCatalog.visualCards(for: .waterfall)
        XCTAssertTrue(hasKey(waterfall, "waterfall", "increaseColor"))
        XCTAssertTrue(hasKey(waterfall, "waterfall", "decreaseColor"))
    }

    // MARK: - General-tab cards

    func testGeneralTabCardsCoverTheContainerChrome() {
        // VisualView draws title, subtitle, divider, background, border, shadow and padding.
        let cards = FormatCatalog.generalCards(for: .clusteredColumn)
        for expected in ["title", "subtitle", "divider", "background", "border", "shadow", "padding"] {
            XCTAssertNotNil(cards.first { $0.card == expected }, "General tab is missing the \(expected) card")
        }
        // Properties leads and Alt text closes the tab, as in Power BI.
        XCTAssertEqual(cards.first?.role, .position)
        XCTAssertEqual(cards.last?.role, .altText)
        let title = cards.first { $0.card == "title" }
        XCTAssertEqual(Set(title?.properties.map(\.key) ?? []),
                       ["show", "text", "alignment", "size", "bold", "color"])
        // Data visuals default to a visible, opaque background.
        XCTAssertEqual(cards.first { $0.card == "background" }?.properties.first { $0.key == "show" }?.defaultValue,
                       .bool(true))
        XCTAssertEqual(cards.first { $0.card == "background" }?.properties.first { $0.key == "transparency" }?.defaultValue,
                       .number(0))
    }

    func testGeneralTabCardsAdaptToPageElements() {
        // Page elements hide their header by default, so the title card drops bold and alignment
        // (VisualView ignores them for elements) and the background defaults to hidden.
        let cards = FormatCatalog.generalCards(for: .textBox)
        for expected in ["title", "subtitle", "divider", "background", "border", "shadow", "padding"] {
            XCTAssertNotNil(cards.first { $0.card == expected }, "General tab is missing the \(expected) card")
        }
        let title = cards.first { $0.card == "title" }
        XCTAssertNil(title?.properties.first { $0.key == "bold" })
        XCTAssertNil(title?.properties.first { $0.key == "alignment" })
        XCTAssertEqual(cards.first { $0.card == "background" }?.properties.first { $0.key == "show" }?.defaultValue,
                       .bool(false))
        // The border still honours its width default of 1 (VisualView's stroke default).
        XCTAssertEqual(cards.first { $0.card == "border" }?.properties.first { $0.key == "width" }?.defaultValue,
                       .number(1))
    }

    // MARK: - Search

    func testSearchFilterReturnsEverythingForAnEmptyQuery() {
        let cards = FormatCatalog.visualCards(for: .table)
        XCTAssertEqual(FormatCatalog.filter(cards, query: "").count, cards.count)
        XCTAssertEqual(FormatCatalog.filter(cards, query: "   ").count, cards.count)
    }

    func testSearchFilterNarrowsToMatchingProperties() {
        // The table's grid card carries "Row padding" (TableFamily: rowPadding).
        let cards = FormatCatalog.visualCards(for: .table)
        let matches = FormatCatalog.filter(cards, query: "row padding")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.card, "grid")
        XCTAssertEqual(matches.first?.properties.map(\.key), ["rowPadding"])
    }

    func testSearchFilterMatchesWholeCardsByCardName() {
        // Querying the card's name returns the whole card, un-narrowed.
        let cards = FormatCatalog.visualCards(for: .table)
        let grid = cards.first { $0.card == "grid" }
        let matches = FormatCatalog.filter(cards, query: "grid")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.card, "grid")
        XCTAssertEqual(matches.first?.properties, grid?.properties)
        // Matching is case-insensitive.
        XCTAssertEqual(FormatCatalog.filter(cards, query: "ROW PADDING").first?.properties.map(\.key), ["rowPadding"])
    }

    func testSearchFilterReturnsNothingWhenNothingMatches() {
        let cards = FormatCatalog.visualCards(for: .table)
        XCTAssertTrue(FormatCatalog.filter(cards, query: "zzz no formatting option matches this").isEmpty)
    }

    // MARK: - Per-card reset

    func testOverrideCheckEnablesPerCardReset() {
        var spec = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 400, height: 300))
        guard let title = FormatCatalog.generalCards(for: .clusteredColumn).first(where: { $0.card == "title" }) else {
            return XCTFail("the General tab should carry a title card")
        }
        // A fresh spec has no overrides, so reset is disabled.
        XCTAssertFalse(FormatCatalog.isOverridden(title, in: spec))
        // Any override in the card enables it…
        spec.setFmt("title", "show", .bool(false))
        XCTAssertTrue(FormatCatalog.isOverridden(title, in: spec))
        // …and resetting every key back disables it again.
        for property in title.properties { spec.setFmt("title", property.key, nil) }
        XCTAssertFalse(FormatCatalog.isOverridden(title, in: spec))
        // Overrides in other cards do not enable this card's reset.
        spec.setFmt("background", "color", .string("#123456"))
        XCTAssertFalse(FormatCatalog.isOverridden(title, in: spec))
    }

    // MARK: - Chart key uniqueness

    func testChartFormatKeysAreUniquePerCard() {
        for type in VisualType.allCases {
            let properties = ChartFormatCatalog.properties(for: type)
            var byCard: [String: [String]] = [:]
            for property in properties { byCard[property.card, default: []].append(property.key) }
            for (card, keys) in byCard {
                XCTAssertEqual(keys.count, Set(keys).count,
                               "\(type.displayName) lists the key \(card).\(keys.duplicates.first ?? "") more than once")
            }
            let ids = properties.map { $0.card + "." + $0.key }
            XCTAssertEqual(ids.count, Set(ids).count, "\(type.displayName) has duplicate chart format ids")
        }
    }

    // MARK: - Number input (review finding 1, 7)

    func testNumberInputClampsRejectsAndClears() {
        // Histogram bins accept 0…200 (HistogramModel.maxBins).
        XCTAssertEqual(FormatCatalog.numberInput("12", bounds: 0...200), .value(12))
        XCTAssertEqual(FormatCatalog.numberInput(" 1,234.5 ", bounds: 0...4_000), .value(1234.5))
        XCTAssertEqual(FormatCatalog.numberInput("1e19", bounds: 0...200), .value(200))
        XCTAssertEqual(FormatCatalog.numberInput("-5", bounds: 0...200), .value(0))
        XCTAssertEqual(FormatCatalog.numberInput("", bounds: 0...200), .clear)
        XCTAssertEqual(FormatCatalog.numberInput("   ", bounds: 0...200), .clear)
        // Not a number, or not finite: an inline message, never a silent reset or a stored value.
        for bad in ["abc", "inf", "nan", "1e999", "12px"] {
            XCTAssertEqual(FormatCatalog.numberInput(bad, bounds: 0...200), .invalid("Enter a number from 0 to 200"), bad)
        }
        // Position and size have no automatic state.
        XCTAssertEqual(FormatCatalog.numberInput("", bounds: 20...4_000, allowsEmpty: false), .invalid("Enter a number"))
    }

    func testStoredValuesAreClampedAndCleared() {
        guard let bins = FormatCatalog.visualCards(for: .histogram).flatMap(\.properties).first(where: { $0.id == "histogram.bins" }),
              let title = FormatCatalog.generalCards(for: .clusteredColumn).flatMap(\.properties).first(where: { $0.id == "title.text" }),
              let units = FormatCatalog.visualCards(for: .clusteredColumn).flatMap(\.properties).first(where: { $0.id == "dataLabels.displayUnits" })
        else { return XCTFail("missing catalog entries") }
        XCTAssertEqual(FormatCatalog.stored(.number(1e19), for: bins), .number(200))
        XCTAssertEqual(FormatCatalog.stored(.number(1e9), for: bins), .number(200))
        XCTAssertEqual(FormatCatalog.stored(.number(12), for: bins), .number(12))
        XCTAssertNil(FormatCatalog.stored(.number(.infinity), for: bins))
        XCTAssertNil(FormatCatalog.stored(.number(.nan), for: bins))
        XCTAssertNil(FormatCatalog.stored(nil, for: bins))
        // Finding 4: a cleared string removes the override instead of storing "".
        XCTAssertNil(FormatCatalog.stored(.string(""), for: title))
        XCTAssertEqual(FormatCatalog.stored(.string("Revenue"), for: title), .string("Revenue"))
        // Values of the wrong kind or outside the option list never reach the document.
        XCTAssertNil(FormatCatalog.stored(.string("12"), for: bins))
        XCTAssertNil(FormatCatalog.stored(.string("gazillions"), for: units))
        XCTAssertEqual(FormatCatalog.stored(.string("millions"), for: units), .string("millions"))
    }

    func testClearedTitleRevertsToTheAutomaticTitle() {
        // VisualView.titleText: an absent title.text means the automatic title; "" would hide the block.
        var spec = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 400, height: 300))
        guard let title = FormatCatalog.generalCards(for: .clusteredColumn).flatMap(\.properties).first(where: { $0.id == "title.text" })
        else { return XCTFail("no title.text") }
        spec.setFmt("title", "text", FormatCatalog.stored(.string("Custom"), for: title))
        XCTAssertEqual(spec.fmt("title", "text"), .string("Custom"))
        spec.setFmt("title", "text", FormatCatalog.stored(.string(""), for: title))
        XCTAssertNil(spec.fmt("title", "text"))
        XCTAssertNil(spec.format["title"], "an emptied card leaves no residue in the bag")
    }

    // MARK: - Effective values (findings 5, 7, 10)

    func testValuesResolveThroughThemeDefaults() {
        var spec = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 400, height: 300))
        var theme = ThemeSpec.facet
        guard let width = FormatCatalog.generalCards(for: .clusteredColumn).flatMap(\.properties).first(where: { $0.id == "border.width" })
        else { return XCTFail("no border.width") }
        // Catalog default (VisualView strokes with width 1).
        XCTAssertEqual(FormatCatalog.value(of: width, in: [spec], theme: theme), .same(.number(1)))
        // The theme's visual defaults sit between the override and the catalog default.
        theme.visualDefaults["*"] = ["border": ["width": .number(3)]]
        XCTAssertEqual(FormatCatalog.value(of: width, in: [spec], theme: theme), .same(.number(3)))
        spec.setFmt("border", "width", .number(2))
        XCTAssertEqual(FormatCatalog.value(of: width, in: [spec], theme: theme), .same(.number(2)))
        // A theme default is not an override: reset stays disabled until the visual itself differs.
        var plain = spec; plain.setFmt("border", "width", nil)
        guard let border = FormatCatalog.generalCards(for: .clusteredColumn).first(where: { $0.card == "border" }) else { return XCTFail("no border card") }
        XCTAssertFalse(FormatCatalog.isOverridden(border, in: plain))
        XCTAssertTrue(FormatCatalog.isOverridden(border, in: spec))
    }

    func testAutomaticLegendToggleShowsTheRenderedState() {
        guard let legend = FormatCatalog.visualCards(for: .clusteredColumn).flatMap(\.properties).first(where: { $0.id == "legend.show" })
        else { return XCTFail("no legend.show") }
        var one = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 400, height: 300))
        one.wells[Well.values.rawValue] = [.measure("Sales", "Amount")]
        var two = one
        two.wells[Well.legend.rawValue] = [.column("Sales", "Region")]
        // ChartScaffold shows the legend when there is more than one series.
        XCTAssertEqual(FormatCatalog.isOn(legend, in: [one], theme: .facet), .same(false))
        XCTAssertEqual(FormatCatalog.isOn(legend, in: [two], theme: .facet), .same(true))
        XCTAssertEqual(FormatCatalog.isOn(legend, in: [one, two], theme: .facet), .mixed)
        // A pie hides its legend by default even with several slices (PieChart.swift:83).
        var pie = two; pie.type = .pie
        XCTAssertEqual(FormatCatalog.isOn(legend, in: [pie], theme: .facet), .same(false))
    }

    func testColourWellsPreviewTheRendererFallback() {
        var theme = ThemeSpec.facet
        theme.minimum = "#010203"; theme.maximum = "#040506"; theme.center = "#070809"
        theme.gridline = "#0A0B0C"; theme.accent = "#0D0E0F"; theme.foreground = "#101112"
        func fallback(_ type: VisualType, _ id: String) -> String? {
            FormatCatalog.visualCards(for: type).flatMap(\.properties).first { $0.id == id }
                .map { FormatCatalog.defaultColor(of: $0, theme: theme) }
        }
        XCTAssertEqual(fallback(.heatmap, "heatmap.minColor"), "#010203")
        XCTAssertEqual(fallback(.heatmap, "heatmap.maxColor"), "#040506")
        XCTAssertEqual(fallback(.heatmap, "heatmap.midColor"), "#070809")
        XCTAssertEqual(fallback(.bullet, "bullet.trackColor"), "#0A0B0C")
        XCTAssertEqual(fallback(.bullet, "bullet.barColor"), "#0D0E0F")
        XCTAssertEqual(fallback(.clusteredColumn, "dataLabels.color"), "#101112")
    }

    // MARK: - Position (findings 3, 6)

    func testFrameEditsClampAndAnEmptyRotationMeansNone() {
        var frame = Frame(x: 10, y: 20, width: 300, height: 200)
        frame.rotation = 45
        XCTAssertEqual(FormatCatalog.frame(frame, setting: "x", to: 55)?.x, 55)
        XCTAssertEqual(FormatCatalog.frame(frame, setting: "width", to: 5)?.width, 20, "width is at least 20 pt")
        XCTAssertEqual(FormatCatalog.frame(frame, setting: "height", to: 1e19)?.height, 4_000)
        XCTAssertEqual(FormatCatalog.frame(frame, setting: "rotation", to: 90)?.rotation, 90)
        XCTAssertEqual(FormatCatalog.frame(frame, setting: "rotation", to: nil)?.rotation, 0)
        XCTAssertNil(FormatCatalog.frame(frame, setting: "x", to: nil))
        XCTAssertNil(FormatCatalog.frame(frame, setting: "x", to: .nan))
        XCTAssertNil(FormatCatalog.frame(frame, setting: "depth", to: 3))
    }

    @MainActor func testPositionWritesGoToTheLayoutBeingEdited() {
        let store = DocumentStore(services: .live())
        let id = store.addVisual(.clusteredColumn)
        guard let desktop = store.visual(id)?.frame else { return XCTFail("no visual") }
        store.mobileLayout = true
        guard let spec = store.visual(id), let moved = FormatCatalog.frame(store.frame(of: spec), setting: "x", to: desktop.x + 40) else {
            return XCTFail("no frame")
        }
        store.setFrames([id: moved], name: "Move Visual")
        // The phone frame moved; the desktop frame the Properties card no longer reads did not.
        XCTAssertEqual(store.visual(id)?.frame, desktop)
        XCTAssertEqual(store.visual(id).map { store.frame(of: $0).x }, desktop.x + 40)
    }

    // MARK: - Multi-selection (finding 8)

    func testMultiSelectionKeepsCommonCardsOnly() {
        // Column and line charts share axes, legend, data labels…; bars and lines cards are not common.
        let cards = FormatCatalog.cards(for: [.clusteredColumn, .line], tab: .visual)
        let ids = Set(cards.map(\.card))
        XCTAssertTrue(ids.isSuperset(of: ["xAxis", "yAxis", "legend", "dataLabels", "plotArea", "accessibility"]))
        XCTAssertFalse(ids.contains("bars"))
        XCTAssertFalse(ids.contains("lines"))
        XCTAssertFalse(ids.contains("totalLabels"))
        // A chart and a table share no Visual-tab card.
        XCTAssertTrue(FormatCatalog.cards(for: [.clusteredColumn, .table], tab: .visual).isEmpty)
        // General tab: container chrome is common; Properties and Alt text are single-visual cards.
        let general = FormatCatalog.cards(for: [.clusteredColumn, .table], tab: .general)
        XCTAssertEqual(general.map(\.card), ["title", "subtitle", "divider", "background", "border", "shadow", "padding"])
        // Page elements have no bold / alignment title rows, so a mixed selection drops them.
        let mixed = FormatCatalog.cards(for: [.clusteredColumn, .textBox], tab: .general)
        XCTAssertEqual(mixed.first { $0.card == "title" }?.properties.map(\.key), ["show", "text", "size", "color"])
        // One visual keeps every format card.
        XCTAssertEqual(FormatCatalog.cards(for: [.table], tab: .visual).filter { $0.role == .format }, FormatCatalog.visualCards(for: .table))
    }

    func testMixedValuesUseEachVisualsOwnDefault() {
        guard let radius = FormatCatalog.visualCards(for: .pie).flatMap(\.properties).first(where: { $0.id == "slices.innerRadius" })
        else { return XCTFail("no slices.innerRadius") }
        let frame = Frame(x: 0, y: 0, width: 300, height: 300)
        var pie = VisualSpec(type: .pie, frame: frame), donut = VisualSpec(type: .donut, frame: frame)
        // Pie 0, donut 64 (PieChart.swift:106): different defaults are mixed, not "0".
        XCTAssertEqual(FormatCatalog.value(of: radius, in: [pie, donut], theme: .facet), .mixed)
        XCTAssertEqual(FormatCatalog.value(of: radius, in: [pie], theme: .facet), .same(.number(0)))
        XCTAssertEqual(FormatCatalog.value(of: radius, in: [donut], theme: .facet), .same(.number(64)))
        pie.setFmt("slices", "innerRadius", .number(50)); donut.setFmt("slices", "innerRadius", .number(50))
        XCTAssertEqual(FormatCatalog.value(of: radius, in: [pie, donut], theme: .facet), .same(.number(50)))
    }

    @MainActor func testMultiVisualWriteIsOneUndoStepAndTargetsItsOwnVisuals() {
        let store = DocumentStore(services: .live())
        let a = store.addVisual(.clusteredColumn), b = store.addVisual(.line), c = store.addVisual(.pie)
        // The row was built for a and b; the selection has since moved to c (finding 2).
        store.selection = [c]
        store.updateVisuals([a, b], name: "Format Legend") { $0.setFmt("legend", "position", .string("bottom")) }
        XCTAssertEqual(store.visual(a)?.fmt("legend", "position"), .string("bottom"))
        XCTAssertEqual(store.visual(b)?.fmt("legend", "position"), .string("bottom"))
        XCTAssertNil(store.visual(c)?.fmt("legend", "position"))
        XCTAssertEqual(store.undoName, "Format Legend")
        store.undo()
        XCTAssertNil(store.visual(a)?.fmt("legend", "position"))
        XCTAssertNil(store.visual(b)?.fmt("legend", "position"))
    }

    // MARK: - Search and reset (finding 9)

    func testGeneralSearchFindsPropertiesAndAltText() {
        let cards = FormatCatalog.generalCards(for: .clusteredColumn)
        XCTAssertEqual(FormatCatalog.filter(cards, query: "alt").map(\.card), ["altText"])
        let rotation = FormatCatalog.filter(cards, query: "rotation")
        XCTAssertEqual(rotation.map(\.card), ["position"])
        XCTAssertEqual(rotation.first?.properties.map(\.key), ["rotation"])
        XCTAssertEqual(FormatCatalog.filter(cards, query: "height").first?.properties.map(\.key), ["height"])
        // "Properties" by name keeps the whole card.
        XCTAssertEqual(FormatCatalog.filter(cards, query: "properties").first?.properties.map(\.key), ["x", "y", "width", "height", "rotation"])
    }

    func testResetCoversTheWholeCardWhileASearchNarrowsIt() {
        var spec = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 400, height: 300))
        spec.setFmt("title", "color", .string("#FF0000"))
        let narrowed = FormatCatalog.filter(FormatCatalog.generalCards(for: .clusteredColumn), query: "bold")
        guard let title = narrowed.first(where: { $0.card == "title" }) else { return XCTFail("no title card") }
        XCTAssertEqual(title.properties.map(\.key), ["bold"])
        // The hidden colour override still counts, and reset clears every key of the card.
        XCTAssertTrue(FormatCatalog.isOverridden(title, in: spec))
        XCTAssertEqual(Set(title.resetKeys), ["show", "text", "alignment", "size", "bold", "color"])
        for key in title.resetKeys { spec.setFmt(title.card, key, nil) }
        XCTAssertNil(spec.fmt("title", "color"))
    }

    func testOptionNamesReadAsWords() {
        XCTAssertEqual(FormatPropertyRow.optionName("insideEnd"), "Inside end")
        XCTAssertEqual(FormatPropertyRow.optionName("auto"), "Automatic")
        XCTAssertEqual(FormatPropertyRow.optionName("thousands"), "Thousands")
        XCTAssertEqual(FormatPropertyRow.optionName("categoryPercent"), "Category and percent")
    }
}

extension Collection where Element == String {
    /// The first element that appears more than once, for failure messages.
    var duplicates: [String] {
        var seen: Set<String> = [], repeated: [String] = []
        for element in self where !seen.insert(element).inserted { repeated.append(element) }
        return repeated
    }
}
