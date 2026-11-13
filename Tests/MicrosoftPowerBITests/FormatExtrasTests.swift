import XCTest
import FacetCore
import FacetVisuals
@testable import MicrosoftPowerBI

/// Style presets, conditional-formatting entry points, on-object elements, the format painter and
/// the Copy / Paste / Reset Formatting commands. Expected values are worked out from the rules in
/// the feature reference (section 7, "Formatting visuals") and the catalog entries by hand.
final class FormatExtrasTests: XCTestCase {
    private let frame = Frame(x: 0, y: 0, width: 300, height: 200)

    // MARK: - Format painter

    func testPaintingCopiesFormattingButNotText() {
        var source = VisualSpec(type: .clusteredColumn, frame: frame)
        source.setFmt("legend", "position", .string("bottom"))
        source.setFmt("background", "color", .string("#102030"))
        source.setFmt("title", "text", .string("Revenue by region"))
        source.setFmt("xAxis", "title", .string("Region"))
        var target = VisualSpec(type: .clusteredColumn, frame: frame)
        target.setFmt("title", "text", .string("Units by month"))
        target.setFmt("border", "show", .bool(true))
        target.setFmt("columnWidths", "Region", .number(120))

        let painted = FormatPainter.painted(target, from: source)
        XCTAssertEqual(painted["legend"]?["position"], .string("bottom"))
        XCTAssertEqual(painted["background"]?["color"], .string("#102030"))
        // Text stays with the visual it describes.
        XCTAssertEqual(painted["title"]?["text"], .string("Units by month"))
        XCTAssertNil(painted["xAxis"]?["title"])
        // Where the source has no override the target goes back to the default.
        XCTAssertNil(painted["border"])
        // Keys the catalog does not describe are not formatting to paint: they are kept.
        XCTAssertEqual(painted["columnWidths"]?["Region"], .number(120))
    }

    func testPaintingAcrossTypesTouchesOnlySharedProperties() {
        var source = VisualSpec(type: .clusteredColumn, frame: frame)
        source.setFmt("bars", "cornerRadius", .number(8))
        source.setFmt("legend", "position", .string("right"))
        source.setFmt("border", "show", .bool(true))
        var target = VisualSpec(type: .line, frame: frame)
        target.setFmt("lines", "width", .number(4))
        let painted = FormatPainter.painted(target, from: source)
        // A line chart has no bars card; its own lines card is untouched.
        XCTAssertNil(painted["bars"])
        XCTAssertEqual(painted["lines"]?["width"], .number(4))
        XCTAssertEqual(painted["legend"]?["position"], .string("right"))
        XCTAssertEqual(painted["border"]?["show"], .bool(true))
        // Column chart onto a table: only the container chrome is shared.
        let table = FormatPainter.painted(VisualSpec(type: .table, frame: frame), from: source)
        XCTAssertEqual(table, ["border": ["show": .bool(true)]])
    }

    func testPaintingClampsValuesFromTheSource() {
        // A hand-edited source file can hold anything; it must not spread.
        var source = VisualSpec(type: .histogram, frame: frame)
        source.setFmt("histogram", "bins", .number(1e19))
        let painted = FormatPainter.painted(VisualSpec(type: .histogram, frame: frame), from: source)
        XCTAssertEqual(painted["histogram"]?["bins"], .number(200))
    }

    func testResetClearsCatalogKeysAndKeepsTheRest() {
        var spec = VisualSpec(type: .table, frame: frame)
        XCTAssertFalse(FormatPainter.hasOverrides(spec))
        spec.setFmt("columnWidths", "Region", .number(120))
        XCTAssertFalse(FormatPainter.hasOverrides(spec), "per-column widths are not catalog formatting")
        spec.setFmt("grid", "rowPadding", .number(9))
        spec.setFmt("title", "text", .string("Orders"))
        XCTAssertTrue(FormatPainter.hasOverrides(spec))
        XCTAssertEqual(FormatPainter.reset(spec), ["columnWidths": ["Region": .number(120)]])
    }

    // MARK: - Style presets

    func testPresetsCardAppearsOnlyWhereTheTypeHasPresets() {
        // The reference lists presets for cards, slicers, tables and matrices.
        for type in [VisualType.card, .slicer, .table, .matrix] {
            XCTAssertEqual(FormatCatalog.cards(for: [type], tab: .visual).first?.role, .presets, type.rawValue)
        }
        XCTAssertNil(FormatCatalog.presetsCard(for: .clusteredColumn))
        XCTAssertFalse(FormatCatalog.cards(for: [.card], tab: .general).contains { $0.role == .presets })
        // Several visuals: only when they are all of one type.
        XCTAssertEqual(FormatCatalog.cards(for: [.card, .card], tab: .visual).first?.role, .presets)
        XCTAssertFalse(FormatCatalog.cards(for: [.card, .multiRowCard], tab: .visual).contains { $0.role == .presets })
    }

    func testApplyingAPresetMergesAndIsRecognised() {
        var spec = VisualSpec(type: .card, frame: frame)
        spec.setFmt("callout", "size", .number(40))
        XCTAssertNil(FormatPresets.active(in: spec, theme: .facet))
        // Card "Minimal": no accent bar, no dividers, regular-weight callout (CardFamily presets).
        let minimal = FormatPresets.applying("Minimal", to: spec, theme: .facet)
        XCTAssertEqual(minimal.fmt("accentBar", "show"), .bool(false))
        XCTAssertEqual(minimal.fmt("layout", "dividers"), .bool(false))
        XCTAssertEqual(minimal.fmt("callout", "bold"), .bool(false))
        XCTAssertEqual(minimal.fmt("callout", "size"), .number(40), "keys the preset does not cover are kept")
        XCTAssertEqual(FormatPresets.active(in: minimal, theme: .facet), "Minimal")
        // Changing one of its keys makes it custom again.
        var edited = minimal
        edited.setFmt("callout", "bold", .bool(true))
        XCTAssertNotEqual(FormatPresets.active(in: edited, theme: .facet), "Minimal")
        // An unknown name changes nothing.
        XCTAssertEqual(FormatPresets.applying("No such style", to: spec, theme: .facet), spec)
    }

    // MARK: - Conditional formatting (fx)

    func testConditionalCardListsTheTargetsOfTheType() {
        // Reference: table and matrix cells take background, font colour, data bars, icons, web URL, image.
        let table = FormatCatalog.cards(for: [.table], tab: .visual).last
        XCTAssertEqual(table?.role, .conditional)
        XCTAssertEqual(table?.properties.map(\.key), ["background", "fontColor", "dataBars", "icons", "webURL", "image"])
        // Chart data points take a colour.
        XCTAssertEqual(FormatCatalog.conditionalCard(for: .clusteredColumn)?.properties.map(\.key), ["dataPointColor"])
        // Slicers and page elements have no data-driven property besides the title.
        XCTAssertNil(FormatCatalog.conditionalCard(for: .slicer))
        XCTAssertNil(FormatCatalog.conditionalCard(for: .textBox))
        // The card is for one visual: a rule names that visual's fields.
        XCTAssertFalse(FormatCatalog.cards(for: [.table, .table], tab: .visual).contains { $0.role == .conditional })
        // Search reaches the rows.
        let found = FormatCatalog.filter(FormatCatalog.cards(for: [.table], tab: .visual), query: "data bars")
        XCTAssertEqual(found.first { $0.role == .conditional }?.properties.map(\.key), ["dataBars"])
    }

    func testTitleTextOffersFxWhereTitlesCanBeDynamic() {
        func title(_ type: VisualType) -> FormatProperty? {
            FormatCatalog.generalCards(for: type).flatMap(\.properties).first { $0.id == "title.text" }
        }
        guard let chart = title(.clusteredColumn), let box = title(.textBox),
              let color = FormatCatalog.generalCards(for: .clusteredColumn).flatMap(\.properties).first(where: { $0.id == "title.color" })
        else { return XCTFail("missing title entries") }
        XCTAssertEqual(FormatCatalog.fxTarget(of: chart, type: .clusteredColumn), .title)
        XCTAssertNil(FormatCatalog.fxTarget(of: box, type: .textBox), "page elements have no dynamic title")
        XCTAssertNil(FormatCatalog.fxTarget(of: color, type: .clusteredColumn))
    }

    func testNewRuleUsesTheBuildPaneDefaults() {
        var spec = VisualSpec(type: .table, frame: frame)
        spec.wells[Well.values.rawValue] = [.column("Sales", "Region"), .measure("Sales", "Amount")]
        let rule = ConditionalFormatsSection.newRule(.background, for: spec)
        XCTAssertEqual(rule.target, .background)
        XCTAssertEqual(rule.mode, .gradient)
        XCTAssertEqual(rule.appliesToKey, FieldRef.column("Sales", "Region").key)
        XCTAssertEqual(rule.basedOn?.key, FieldRef.measure("Sales", "Amount").key)
        XCTAssertEqual(ConditionalFormatsSection.newRule(.title, for: spec).mode, .fieldValue)
    }

    // MARK: - On-object elements

    func testOnObjectElementsListCardsWithTheirSwitches() {
        let elements = FormatCatalog.elements(for: .clusteredColumn)
        func element(_ card: String) -> FormatCatalog.Element? { elements.first { $0.card.card == card } }
        XCTAssertEqual(element("legend")?.tab, .visual)
        XCTAssertEqual(element("legend")?.toggle?.id, "legend.show")
        XCTAssertEqual(element("dataLabels")?.toggle?.id, "dataLabels.show")
        XCTAssertEqual(element("title")?.tab, .general)
        XCTAssertEqual(element("title")?.toggle?.id, "title.show")
        // Bars cannot be hidden; padding has no switch.
        XCTAssertNotNil(element("bars"))
        XCTAssertNil(element("bars")?.toggle)
        XCTAssertNil(element("padding")?.toggle)
        // Properties, Alt text, presets and conditional formatting are not elements of the visual.
        XCTAssertFalse(elements.contains { $0.card.role != .format })
        XCTAssertEqual(elements.count, Set(elements.map(\.id)).count)
    }

    // MARK: - Commands

    @MainActor func testFormattingCommandsAreRegisteredAndOnTheRibbon() {
        Features.registerAll()
        for id in ["format.copyFormatting", "format.pasteFormatting", "format.resetFormatting", "edit.formatPainter"] {
            XCTAssertNotNil(AppCommands.command(id), "\(id) is not registered")
        }
        XCTAssertEqual(AppCommands.all.filter { $0.id.hasPrefix("format.copyFormatting") }.count, 1)
        // The ribbon's Format tab names the same ids.
        var ribbon: Set<String> = []
        for tab in RibbonLayout.tabs where tab.id == .format {
            for group in tab.groups { for item in group.items { if case .button(let c) = item.control { ribbon.insert(c.id) } } }
        }
        XCTAssertTrue(ribbon.isSuperset(of: ["format.copyFormatting", "format.pasteFormatting", "format.resetFormatting"]))
        XCTAssertNotNil(Features.visualHeaderAccessory, "on-object formatting is not registered")
    }

    @MainActor func testCopyPasteAndResetFormattingCommands() {
        Features.registerAll()
        FormatClipboard.source = nil
        let store = DocumentStore(services: .live())
        store.view = .report
        let a = store.addVisual(.clusteredColumn), b = store.addVisual(.line), c = store.addVisual(.pie)
        store.updateVisuals([a], name: "Format") { $0.setFmt("legend", "position", .string("bottom")); $0.setFmt("shadow", "show", .bool(true)) }

        store.selection = [b, c]
        guard let paste = AppCommands.command("format.pasteFormatting"), let copy = AppCommands.command("format.copyFormatting"),
              let reset = AppCommands.command("format.resetFormatting") else { return XCTFail("commands missing") }
        XCTAssertFalse(paste.isEnabled(store), "nothing copied yet")
        XCTAssertFalse(copy.isEnabled(store), "copying needs exactly one visual")
        store.selection = [a]
        XCTAssertTrue(copy.isEnabled(store))
        AppCommands.run("format.copyFormatting", store)

        store.selection = [b, c]
        XCTAssertTrue(paste.isEnabled(store))
        AppCommands.run("format.pasteFormatting", store)
        for id in [b, c] {
            XCTAssertEqual(store.visual(id)?.fmt("legend", "position"), .string("bottom"))
            XCTAssertEqual(store.visual(id)?.fmt("shadow", "show"), .bool(true))
        }
        // One undo step for the whole paste.
        XCTAssertEqual(store.undoName, "Paste Formatting")
        store.undo()
        XCTAssertNil(store.visual(b)?.fmt("legend", "position"))
        XCTAssertNil(store.visual(c)?.fmt("shadow", "show"))

        // Reset is offered only when there is something to reset.
        XCTAssertFalse(reset.isEnabled(store))
        store.selection = [a]
        XCTAssertTrue(reset.isEnabled(store))
        AppCommands.run("format.resetFormatting", store)
        XCTAssertEqual(store.visual(a)?.format, [:])
        FormatClipboard.source = nil
    }

    @MainActor func testFocusRequestNamesItsWindow() {
        let store = DocumentStore(services: .live()), other = DocumentStore(services: .live())
        FormatFocus.shared.open("legend", tab: .visual, in: store)
        XCTAssertEqual(FormatFocus.shared.request?.card, "legend")
        XCTAssertEqual(FormatFocus.shared.request?.store, ObjectIdentifier(store))
        XCTAssertNotEqual(FormatFocus.shared.request?.store, ObjectIdentifier(other))
        XCTAssertEqual(store.inspector, .format)
        XCTAssertTrue(store.inspectorVisible)
        FormatFocus.shared.request = nil
    }
}
