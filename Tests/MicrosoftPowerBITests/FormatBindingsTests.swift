import XCTest
import FacetCore
import FacetVisuals
@testable import MicrosoftPowerBI

/// Measure-driven formatting (fx) on more properties than the title: a field's value, under the
/// visual's filters, sets a subtitle, colours, button text, alt text, a tooltip or a column width.
///
/// Over `ReportFixture`: Total is 150 overall; North 30; South 70; East 50; North and Apple 10.
/// Destination is "Details" above 100, otherwise "Nowhere".
@MainActor
final class FormatBindingsTests: XCTestCase {
    private func binding(_ card: String, _ key: String, _ kind: FormatBinding.Kind, _ field: FieldRef,
                         _ mode: ConditionalFormat.Mode = .fieldValue) -> FormatBinding {
        var b = FormatBinding(card: card, key: key, kind: kind)
        b.field = field
        b.mode = mode
        return b
    }

    private func rule(_ op: FilterOperator, _ value: Double, color: String = "#000000", number: Double? = nil) -> ConditionalFormat.Rule {
        var r = ConditionalFormat.Rule()
        r.op = op; r.value = value; r.upperOp = nil; r.color = color; r.number = number
        return r
    }

    private func filtered(_ pairs: [(FieldRef, String)]) -> VisualRequest {
        var request = VisualRequest()
        request.filters = pairs.map { field, value in
            var f = FilterSpec(field: field)
            f.values = [.string(value)]
            return f
        }
        return request
    }

    func testColourAndTextPropertiesFollowTheVisualsFilters() {
        var chart = ReportFixture.chart()
        chart.setFormatBinding("subtitle", "text", binding("subtitle", "text", .text, ReportFixture.total))
        var background = binding("background", "color", .color, ReportFixture.total, .rules)
        background.rules = [rule(.greaterOrEqual, 100, color: "#FF0000"), rule(.greaterOrEqual, 0, color: "#00FF00")]
        chart.setFormatBinding("background", "color", background)
        var labels = binding("dataLabels", "color", .color, ReportFixture.total, .gradient)
        labels.minColor = "#000000"; labels.maxColor = "#FFFFFF"; labels.minValue = 0; labels.maxValue = 200
        chart.setFormatBinding("dataLabels", "color", labels)

        let all = ReportFixture.engine().visualData(spec: chart, request: VisualRequest())
        XCTAssertNil(all.error)
        XCTAssertEqual(all.formatOverrides["subtitle"]?["text"], .string("150"))
        // 150 meets the first rule.
        XCTAssertEqual(all.formatOverrides["background"]?["color"], .string("#FF0000"))
        // 150 is 0.75 of the way from 0 to 200: 0.75 × 255 = 191.25 → 191 = BF.
        XCTAssertEqual(all.formatOverrides["dataLabels"]?["color"], .string("#BFBFBF"))

        let north = ReportFixture.engine().visualData(spec: chart, request: filtered([(ReportFixture.region, "North")]))
        XCTAssertEqual(north.formatOverrides["subtitle"]?["text"], .string("30"))
        // 30 fails "≥ 100" and meets "≥ 0".
        XCTAssertEqual(north.formatOverrides["background"]?["color"], .string("#00FF00"))
        // 30 / 200 = 0.15; 0.15 × 255 = 38.25 → 38 = 26.
        XCTAssertEqual(north.formatOverrides["dataLabels"]?["color"], .string("#262626"))
    }

    func testButtonTextAltTextAndTooltipFollowSelections() {
        var button = VisualSpec(type: .button, frame: Frame(x: 0, y: 0, width: 120, height: 40))
        button.setFormatBinding("text", "text", binding("text", "text", .text, ReportFixture.destination))
        button.setFormatBinding(FormatBinding.altTextCard, "text", binding(FormatBinding.altTextCard, "text", .text, ReportFixture.total))
        button.setFormatBinding(FormatBinding.actionCard, "tooltip", binding(FormatBinding.actionCard, "tooltip", .text, ReportFixture.total))

        let all = ReportFixture.engine().visualData(spec: button, request: VisualRequest())
        XCTAssertEqual(all.formatOverrides["text"]?["text"], .string("Details"))
        XCTAssertEqual(all.formatOverrides[FormatBinding.altTextCard]?["text"], .string("150"))

        // A selection on another visual filters a page element (it has no points to highlight).
        var request = VisualRequest()
        request.highlights = [[ReportFixture.point(ReportFixture.region, "South")]]
        let south = ReportFixture.engine().visualData(spec: button, request: request)
        let shown = button.applyingFormatOverrides(button.boundFormatOverrides(south.formatOverrides))
        XCTAssertEqual(shown.fmt("text", "text"), .string("Nowhere"))
        XCTAssertEqual(shown.altText, "70")
        XCTAssertEqual(shown.action?.tooltip, "70")
        XCTAssertEqual(shown.action?.kind, ActionSpec.Kind.none)
    }

    func testTableColumnWidthsByRuleAndByValue() {
        var table = VisualSpec(type: .table, frame: Frame(x: 0, y: 0, width: 300, height: 200))
        table.setFields(.values, [ReportFixture.region, ReportFixture.amount])
        var width = binding("columnWidths", "Sum of Amount", .number, ReportFixture.total, .rules)
        width.rules = [rule(.greaterOrEqual, 100, number: 200), rule(.greaterOrEqual, 0, number: 80)]
        table.setFormatBinding("columnWidths", "Sum of Amount", width)
        table.setFormatBinding("columnWidths", "Region", binding("columnWidths", "Region", .number, ReportFixture.total))

        let all = ReportFixture.engine().visualData(spec: table, request: VisualRequest())
        XCTAssertEqual(all.formatOverrides["columnWidths"]?["Sum of Amount"], .number(200))
        XCTAssertEqual(all.formatOverrides["columnWidths"]?["Region"], .number(150))

        let east = ReportFixture.engine().visualData(spec: table, request: filtered([(ReportFixture.region, "East")]))
        XCTAssertEqual(east.formatOverrides["columnWidths"]?["Sum of Amount"], .number(80))
        XCTAssertEqual(east.formatOverrides["columnWidths"]?["Region"], .number(50))

        // North and Apple is 10: a width keeps to the Format pane's 28 pt minimum.
        let small = ReportFixture.engine().visualData(spec: table, request: filtered([(ReportFixture.region, "North"), (ReportFixture.product, "Apple")]))
        XCTAssertEqual(small.formatOverrides["columnWidths"]?["Region"], .number(28))
    }

    func testOutputsThatGiveNothingLeaveTheStaticValue() {
        let color = FormatBinding(card: "background", key: "color", kind: .color)
        XCTAssertEqual(FormatBindings.output(color, value: .string("red"), format: ""), .string("#FF453A"))
        XCTAssertEqual(FormatBindings.output(color, value: .string("#00ff00"), format: ""), .string("#00ff00"))
        XCTAssertNil(FormatBindings.output(color, value: .string("not a colour"), format: ""))
        XCTAssertNil(FormatBindings.output(color, value: .null, format: ""))

        let text = FormatBinding(card: "subtitle", key: "text", kind: .text)
        XCTAssertNil(FormatBindings.output(text, value: .null, format: ""))
        XCTAssertEqual(FormatBindings.output(text, value: .double(0.25), format: "0.0%"), .string("25.0%"))
        var textRules = text
        textRules.mode = .rules
        XCTAssertNil(FormatBindings.output(textRules, value: .double(1), format: ""))

        // A blank value meets an "is blank" rule; a value no rule meets gives nothing.
        var rules = color
        rules.mode = .rules
        rules.rules = [rule(.isBlank, 0, color: "#123456"), rule(.greaterThan, 10, color: "#654321")]
        XCTAssertEqual(FormatBindings.output(rules, value: .null, format: ""), .string("#123456"))
        XCTAssertEqual(FormatBindings.output(rules, value: .double(11), format: ""), .string("#654321"))
        XCTAssertNil(FormatBindings.output(rules, value: .double(10), format: ""))

        var width = FormatBinding(card: "columnWidths", key: "Region", kind: .number)
        XCTAssertNil(FormatBindings.output(width, value: .string("wide"), format: ""))
        XCTAssertNil(FormatBindings.output(width, value: .double(.infinity), format: ""))
        XCTAssertEqual(FormatBindings.output(width, value: .double(5_000), format: ""), .number(2_000))
        width.mode = .gradient
        XCTAssertNil(FormatBindings.output(width, value: .double(100), format: ""))
    }

    func testFormatPaneOffersFxOnColoursTextsAndColumnWidths() throws {
        let general = FormatCatalog.generalCards(for: .clusteredColumn).flatMap(\.properties)
        func kind(_ id: String, in list: [FormatProperty]) throws -> FormatBinding.Kind? {
            FormatBindings.kind(of: try XCTUnwrap(list.first { $0.id == id }, id))
        }
        XCTAssertEqual(try kind("subtitle.text", in: general), .text)
        XCTAssertEqual(try kind("background.color", in: general), .color)
        XCTAssertEqual(try kind("subtitle.color", in: general), .color)
        // The title has its own fx (a dynamic title); widths, sizes and switches have none.
        XCTAssertNil(try kind("title.text", in: general))
        XCTAssertNil(try kind("border.width", in: general))
        XCTAssertNil(try kind("background.show", in: general))

        let chart = FormatCatalog.visualCards(for: .clusteredColumn).flatMap(\.properties)
        XCTAssertEqual(try kind("dataLabels.color", in: chart), .color)
        let button = FormatCatalog.visualCards(for: .button).flatMap(\.properties)
        XCTAssertEqual(try kind("text.text", in: button), .text)

        var table = VisualSpec(type: .table, frame: Frame(x: 0, y: 0, width: 300, height: 200))
        table.setFields(.values, [ReportFixture.region, ReportFixture.amount])
        let widths = try XCTUnwrap(FormatCatalog.perFieldCards(for: table).first { $0.card == "columnWidths" })
        XCTAssertEqual(widths.properties.map { FormatBindings.kind(of: $0) }, [.number, .number])
        XCTAssertEqual(widths.properties.map(FormatBindingButton.name(of:)), ["width of Region", "width of Sum of Amount"])

        // Buttons, shapes and images get an Action card (its tooltip) just before Alt text.
        XCTAssertEqual(FormatCatalog.generalCards(for: .button).suffix(2).map(\.role), [.action, .altText])
        XCTAssertEqual(FormatCatalog.generalCards(for: .image).suffix(2).map(\.role), [.action, .altText])
        XCTAssertFalse(FormatCatalog.generalCards(for: .textBox).contains { $0.role == .action })
        XCTAssertFalse(FormatCatalog.generalCards(for: .clusteredColumn).contains { $0.role == .action })

        XCTAssertEqual(FormatBindingButton.name(of: try XCTUnwrap(general.first { $0.id == "background.color" })), "background colour")
        XCTAssertEqual(FormatBindingButton.name(of: try XCTUnwrap(general.first { $0.id == "subtitle.text" })), "subtitle text")
    }

    func testNewBindingsStartFromTheVisualsFirstValue() {
        let chart = ReportFixture.chart()
        let text = FormatBindings.newBinding(card: "subtitle", key: "text", kind: .text, for: chart)
        XCTAssertEqual(text.field?.key, ReportFixture.amount.key)
        XCTAssertEqual(text.mode, .fieldValue)
        let width = FormatBindings.newBinding(card: "columnWidths", key: "Region", kind: .number, for: chart)
        XCTAssertEqual(width.mode, .rules)
        XCTAssertEqual(width.rules.map(\.number), [120])
        XCTAssertEqual(FormatBindings.modes(for: .text), [.fieldValue])
        XCTAssertEqual(FormatBindings.modes(for: .color), [.gradient, .rules, .fieldValue])
    }

    func testTheDocumentQueriesPageElementsWithBindings() async throws {
        let store = ReportFixture.store()
        var button = VisualSpec(type: .button, frame: Frame(x: 0, y: 0, width: 120, height: 40))
        let plain = button
        button.id = UUID()
        button.setFormatBinding("text", "text", binding("text", "text", .text, ReportFixture.total))
        XCTAssertTrue(FormatBindings.queriesData(button))
        XCTAssertFalse(FormatBindings.queriesData(plain))
        XCTAssertTrue(FormatBindings.queriesData(ReportFixture.chart()))

        store.mutate("Add", invalidates: .model) { $0.report.pages[0].visuals = [button, plain] }
        for _ in 0..<200 where store.visualData[button.id]?.formatOverrides.isEmpty ?? true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.visualData[button.id]?.formatOverrides["text"]?["text"], .string("150"))
        XCTAssertNil(store.visualData[plain.id])
    }

    func testBindingsSurviveSavingAndOldVisualsOpen() throws {
        var chart = ReportFixture.chart()
        let old = try JSONEncoder().encode(chart)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("formatBindings"))
        XCTAssertNil(try JSONDecoder().decode(VisualSpec.self, from: old).formatBindings)

        var width = binding("columnWidths", "Region", .number, ReportFixture.total, .rules)
        width.rules = [rule(.greaterThan, 5, number: 90)]
        chart.setFormatBinding("columnWidths", "Region", width)
        let decoded = try JSONDecoder().decode(VisualSpec.self, from: JSONEncoder().encode(chart))
        XCTAssertEqual(decoded.formatBindings, chart.formatBindings)
        XCTAssertEqual(decoded.formatBinding("columnWidths", "Region")?.rules.first?.number, 90)

        // Setting nil removes the binding, and the list with it.
        chart.setFormatBinding("columnWidths", "Region", nil)
        XCTAssertNil(chart.formatBindings)
    }
}
