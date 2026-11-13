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
    /// - Scatter's renderer reads no type-specific format keys today; word cloud draws container
    ///   chrome only.
    /// - Script visuals render the app's script output (`spec.imageData`); paginated report, Power
    ///   Apps and metrics are embedded web views — none has format keys in the component catalog.
    ///   (Power automate does: the "Run flow" button label.)
    private static let typesWithoutVisualCards: [VisualType: String] = [
        .keyInfluencers: "app-supplied through VisualContext.extensionView and honours no format keys",
        .decompositionTree: "app-supplied through VisualContext.extensionView and honours no format keys",
        .narrative: "app-supplied through VisualContext.extensionView and honours no format keys",
        .qna: "app-supplied through VisualContext.extensionView and honours no format keys",
        .scatter: "the renderer reads no type-specific format keys today",
        .wordCloud: "the renderer draws container chrome only",
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
                    if case .enumeration(let options) = property.kind {
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
        XCTAssertNil(headers?.properties.first { $0.key == "fontSize" }?.defaultValue)
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
            let properties = ChartFormatProperties.properties(for: type)
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
}

extension Collection where Element == String {
    /// The first element that appears more than once, for failure messages.
    var duplicates: [String] {
        var seen: Set<String> = [], repeated: [String] = []
        for element in self where !seen.insert(element).inserted { repeated.append(element) }
        return repeated
    }
}
