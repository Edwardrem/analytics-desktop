import XCTest
import CoreGraphics
import FacetCore
@testable import MicrosoftPowerBI

/// The checks behind the assistant's authoring tools: field references resolve against the model, fields land
/// in the wells a person would drag them to, and new visuals never overlap the ones already on the page.
@MainActor
final class AssistantAuthoringTests: XCTestCase {
    private typealias A = AssistantAuthoring
    private let page = CGSize(width: 1280, height: 720)

    private func sum(_ f: FieldRef) -> Aggregation { ReportFixture.store().defaultAggregation(for: f) }

    // MARK: References

    func testReferencesResolveToModelFields() throws {
        let model = ReportFixture.model()
        XCTAssertEqual(try A.resolve("'Sales'[Region]", in: model).key, FieldRef.column("Sales", "Region").key)
        XCTAssertEqual(try A.resolve("sales[region]", in: model).key, FieldRef.column("Sales", "Region").key, "names match without case, as in DAX")
        XCTAssertEqual(try A.resolve("[Total]", in: model).key, FieldRef.measure("Sales", "Total").key)
        XCTAssertEqual(try A.resolve("[Amount]", in: model).key, FieldRef.column("Sales", "Amount").key, "a bare column name is fine when one table has it")
        XCTAssertEqual(try A.resolve("Sales[Total]", in: model).key, FieldRef.measure("Sales", "Total").key)
    }

    func testUnknownAndAmbiguousReferencesAreRejectedWithHelp() {
        var model = ReportFixture.model()
        model.tables.append(ModelTable(name: "Targets", columns: [ModelColumn(name: "Region", dataType: .text)]))
        XCTAssertThrowsError(try A.resolve("[Region]", in: model)) { error in
            XCTAssertEqual(error as? A.Problem, .ambiguousField("[Region]", tables: ["Sales", "Targets"]))
        }
        XCTAssertThrowsError(try A.resolve("[Tot]", in: model)) { error in
            XCTAssertEqual(error as? A.Problem, .unknownField("[Tot]", suggestions: ["[Total]"]))
        }
        XCTAssertThrowsError(try A.resolve("'Budget'[Amount]", in: model)) { error in
            XCTAssertEqual(error as? A.Problem, .unknownTable("Budget"))
        }
        XCTAssertThrowsError(try A.resolve("Amount", in: model)) { error in
            XCTAssertEqual(error as? A.Problem, .badReference("Amount"))
        }
    }

    func testVisualTypeNames() {
        XCTAssertEqual(A.visualType("column"), .clusteredColumn)
        XCTAssertEqual(A.visualType("Clustered bar chart"), .clusteredBar)
        XCTAssertEqual(A.visualType("lineClusteredColumn"), .lineClusteredColumn)
        XCTAssertEqual(A.visualType("text box"), .textBox)
        XCTAssertNil(A.visualType("hologram"))
    }

    // MARK: Wells

    func testColumnChartPutsTheCategoryOnTheAxisAndNumbersInValues() throws {
        let placed = try A.bind([.init(reference: "'Sales'[Region]"), .init(reference: "[Total]"), .init(reference: "Sales[Amount]")],
                                to: .clusteredColumn, model: ReportFixture.model(), defaultAggregation: sum)
        XCTAssertEqual(placed.map(\.0), [.category, .values, .values])
        XCTAssertEqual(placed.map(\.1.key), [FieldRef.column("Sales", "Region"), .measure("Sales", "Total"), .column("Sales", "Amount", .sum)].map(\.key))
    }

    func testNamedWellsAndAggregationsAreHonouredAndChecked() throws {
        let model = ReportFixture.model()
        let placed = try A.bind([.init(reference: "[Region]", well: "legend"), .init(reference: "[Amount]", aggregation: "avg")],
                                to: .clusteredColumn, model: model, defaultAggregation: sum)
        XCTAssertEqual(placed.map(\.0), [.legend, .values])
        XCTAssertEqual(placed[1].1.aggregation, .average)
        XCTAssertThrowsError(try A.bind([.init(reference: "[Total]", well: "axis")], to: .clusteredColumn, model: model, defaultAggregation: sum)) { error in
            XCTAssertEqual(error as? A.Problem, .measureInGroupingWell("[Total]", well: Well.category.displayName))
        }
        XCTAssertThrowsError(try A.bind([.init(reference: "[Total]", well: "size")], to: .pie, model: model, defaultAggregation: sum)) { error in
            guard case .unknownWell("size", _, let wells)? = error as? A.Problem else { return XCTFail("\(error)") }
            XCTAssertEqual(wells, ["legend", "values", "details", "tooltips"])
        }
        XCTAssertThrowsError(try A.bind([.init(reference: "[Amount]", aggregation: "geomean")], to: .card, model: model, defaultAggregation: sum))
    }

    func testTablesKeepTextColumnsAndCardsCountThem() throws {
        let model = ReportFixture.model()
        let table = try A.bind([.init(reference: "[Region]"), .init(reference: "[Amount]")], to: .table, model: model, defaultAggregation: sum)
        XCTAssertEqual(table.map(\.0), [.values, .values])
        XCTAssertEqual(table.map(\.1.aggregation), [Aggregation.none, .sum])
        let card = try A.bind([.init(reference: "[Region]")], to: .card, model: model, defaultAggregation: sum)
        XCTAssertEqual(card.map(\.0), [.values], "a card shows one value per field, so a text column is counted")
        XCTAssertEqual(card.first?.1.aggregation, .count)
    }

    func testBuildSetsTitleAndRefusesAnEmptyChart() throws {
        let frame = Frame(x: 24, y: 24, width: 420, height: 280)
        let spec = try A.build(.init(type: "bar", fields: [.init(reference: "[Channel]"), .init(reference: "[Total]")], title: "Total by channel"),
                               model: ReportFixture.model(), frame: frame, name: "Clustered bar chart", defaultAggregation: sum)
        XCTAssertEqual(spec.type, .clusteredBar)
        XCTAssertEqual(spec.fmtString("title", "text", ""), "Total by channel")
        XCTAssertEqual(A.summary(spec), "\(Well.category.displayName) = Channel; \(Well.values.displayName) = Total")
        XCTAssertThrowsError(try A.build(.init(type: "line"), model: ReportFixture.model(), frame: frame, name: "Line", defaultAggregation: sum)) { error in
            XCTAssertEqual(error as? A.Problem, .noFields(VisualType.line.displayName))
        }
        let text = try A.build(.init(type: "textBox", text: "Sales overview"), model: ReportFixture.model(), frame: frame, name: "Text box", defaultAggregation: sum)
        XCTAssertEqual(text.content, "Sales overview")
    }

    // MARK: Layout

    func testNewVisualsTakeTheNextFreeSpotWithAGap() throws {
        // 420×280 at the 24-point margin; the next must clear the first by 16 points on the 8-point grid
        // (24 + 420 + 16 = 460, next grid line 464); a third no longer fits on the row (464 + 420 + 16 + 420 > 1256),
        // so it starts the next row below the first (24 + 280 + 16 = 320).
        let first = try A.place(.clusteredColumn, page: page, occupied: [])
        XCTAssertEqual(first, Frame(x: 24, y: 24, width: 420, height: 280))
        let second = try A.place(.clusteredColumn, page: page, occupied: [first.cgRect])
        XCTAssertEqual(second, Frame(x: 464, y: 24, width: 420, height: 280))
        let third = try A.place(.clusteredColumn, page: page, occupied: [first.cgRect, second.cgRect])
        XCTAssertEqual(third, Frame(x: 24, y: 320, width: 420, height: 280))
        for (a, b) in [(first, second), (first, third), (second, third)] {
            XCTAssertFalse(a.cgRect.intersects(b.cgRect))
        }
    }

    func testASmallerVisualIsUsedBeforeGivingUp() throws {
        // Only a 336-point strip is free on the right (920…1256): 420 does not fit, three quarters (315×210) does.
        let wall = CGRect(x: 0, y: 0, width: 900, height: 720)
        XCTAssertEqual(try A.place(.clusteredColumn, page: page, occupied: [wall]), Frame(x: 920, y: 24, width: 315, height: 210))
        XCTAssertThrowsError(try A.place(.clusteredColumn, page: page, occupied: [CGRect(x: 0, y: 0, width: 1280, height: 720)])) { error in
            XCTAssertEqual(error as? A.Problem, .noRoom)
        }
    }

    func testANewPageHasCardsOnTopAndChartsInAGrid() {
        // Two 220×130 cards side by side, then two charts sharing the 1232-point width ((1232 − 16) / 2 = 608)
        // and the height left under the band (720 − 24 − 170 = 526).
        let frames = A.pageLayout([.card, .card, .clusteredColumn, .line], page: page)
        XCTAssertEqual(frames, [Frame(x: 24, y: 24, width: 220, height: 130), Frame(x: 260, y: 24, width: 220, height: 130),
                                Frame(x: 24, y: 170, width: 608, height: 526), Frame(x: 648, y: 170, width: 608, height: 526)])
        // Five charts: three columns of (1232 − 32) / 3 = 400, two rows of (672 − 16) / 2 = 328.
        let five = A.pageLayout(Array(repeating: .clusteredBar, count: 5), page: page)
        XCTAssertEqual(five.map(\.x), [24, 440, 856, 24, 440])
        XCTAssertEqual(five.map(\.y), [24, 24, 24, 368, 368])
        XCTAssertEqual(Set(five.map(\.width)), [400])
        XCTAssertEqual(Set(five.map(\.height)), [328])
        for i in five.indices { for j in five.indices where j > i { XCTAssertFalse(five[i].cgRect.intersects(five[j].cgRect)) } }
    }
}
