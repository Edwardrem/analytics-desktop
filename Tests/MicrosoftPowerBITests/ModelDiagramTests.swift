import XCTest
import Combine
import FacetCore
@testable import MicrosoftPowerBI

/// Model-view logic: card layout, hit-testing, relationship line routing and labels, the star
/// auto-arrange, the viewport, drop validation, layout tabs and relationship edits. Expected
/// coordinates are worked out by hand from `ModelDiagram.Metrics`: header 34, row 22, "more" row
/// 22, bottom padding 6, card width 220, padding 40, column gap 60, row gap 80, clearance 24.
final class ModelDiagramTests: XCTestCase {
    private typealias D = ModelDiagram

    /// Sales (3 columns + 1 measure), Product (2 columns), Date (1 column); no relationships.
    private func model() -> SemanticModel {
        var model = SemanticModel()
        var sales = ModelTable(name: "Sales", columns: [ModelColumn(name: "Amount", dataType: .decimal),
                                                        ModelColumn(name: "ProductID", dataType: .integer),
                                                        ModelColumn(name: "OrderDate", dataType: .date)])
        sales.measures = [Measure(name: "Total", expression: "SUM(Sales[Amount])")]
        let product = ModelTable(name: "Product", columns: [ModelColumn(name: "ProductID", dataType: .integer),
                                                            ModelColumn(name: "Name", dataType: .text)])
        let date = ModelTable(name: "Date", columns: [ModelColumn(name: "Date", dataType: .date)])
        model.tables = [sales, product, date]
        return model
    }

    private func relate(_ fromTable: String, _ fromColumn: String, _ toTable: String, _ toColumn: String,
                        _ cardinality: Cardinality = .manyToOne) -> Relationship {
        var r = Relationship(fromTable: fromTable, fromColumn: fromColumn, toTable: toTable, toColumn: toColumn)
        r.cardinality = cardinality
        return r
    }

    /// A user layout with Sales at (40, 40) and Product at (400, 40).
    private func layout() -> ModelLayout {
        var layout = ModelLayout(name: "Layout 1")
        layout.cards = ["Sales": ModelLayout.Card(x: 40, y: 40), "Product": ModelLayout.Card(x: 400, y: 40)]
        return layout
    }

    private func sized(_ names: [String], height: CGFloat = 100) -> [(name: String, size: CGSize)] {
        names.map { ($0, CGSize(width: 220, height: $0 == "Sales" ? 150 : height)) }
    }

    // MARK: Cards

    func testCardSizeFollowsItsFieldsUpToTheStoredHeight() {
        let card = ModelLayout.Card(x: 0, y: 0)   // 220 × 260
        let three = D.cardSize(fieldCount: 3, card: card)
        XCTAssertEqual(three.size, CGSize(width: 220, height: 106), "34 + 3 × 22 + 6")
        XCTAssertEqual(three.visible, 3)
        XCTAssertEqual(three.overflow, 0)

        // 12 fields need 304; in 260 there is room for (260 − 34 − 22 − 6) / 22 = 9 rows.
        let twelve = D.cardSize(fieldCount: 12, card: card)
        XCTAssertEqual(twelve.visible, 9)
        XCTAssertEqual(twelve.overflow, 3)
        XCTAssertEqual(twelve.size, CGSize(width: 220, height: 260), "34 + 9 × 22 + 22 + 6")

        var collapsed = card
        collapsed.collapsed = true
        XCTAssertEqual(D.cardSize(fieldCount: 12, card: collapsed).size, CGSize(width: 220, height: 34))
        XCTAssertEqual(D.cardSize(fieldCount: 0, card: card).size, CGSize(width: 220, height: 40))

        var narrow = card; narrow.width = 100
        var wide = card; wide.width = 900
        XCTAssertEqual(D.cardSize(fieldCount: 1, card: narrow).size.width, 160)
        XCTAssertEqual(D.cardSize(fieldCount: 1, card: wide).size.width, 480)
        // A tiny stored height still shows one row and the "more" row.
        var short = card; short.height = 10
        XCTAssertEqual(D.cardSize(fieldCount: 5, card: short).visible, 1)
        XCTAssertEqual(D.cardSize(fieldCount: 5, card: short).overflow, 4)
    }

    func testCardListsColumnsThenMeasuresWithTheirMarks() throws {
        var model = model()
        model.tables[0].columns[1].isKey = true
        model.tables[0].columns[2].isHidden = true
        model.tables[0].columns.append(ModelColumn(name: "Double", dataType: .decimal, expression: "[Amount] * 2"))
        model.tables[0].isHidden = true
        let card = D.cardLayout(model.tables[0], card: ModelLayout.Card(x: 40, y: 40))
        XCTAssertEqual(card.fields.map(\.name), ["Amount", "ProductID", "OrderDate", "Double", "Total"])
        XCTAssertEqual(card.fields.map(\.kind), [.column, .column, .column, .column, .measure])
        XCTAssertEqual(card.fields.map(\.isKey), [false, true, false, false, false])
        XCTAssertEqual(card.fields.map(\.isHidden), [false, false, true, false, false])
        XCTAssertEqual(card.fields.map(\.isCalculated), [false, false, false, true, true])
        XCTAssertEqual(card.fields[1].glyph, "key")
        XCTAssertTrue(card.isHidden)
        XCTAssertEqual(card.frame, CGRect(x: 40, y: 40, width: 220, height: 150), "34 + 5 × 22 + 6")
        XCTAssertEqual(card.fields[4].ref(in: "Sales"), .measure(table: "Sales", name: "Total"))
        XCTAssertEqual(card.fields[0].ref(in: "Sales"), .column(table: "Sales", name: "Amount"))
    }

    // MARK: Placement

    func testUserLayoutShowsOnlyItsTablesAndAllTablesShowsEverything() {
        let model = model()
        XCTAssertEqual(D.placements(model: model, layout: layout()).map(\.table.name), ["Sales", "Product"])

        // Stored under another spelling: still found.
        var spelled = ModelLayout(name: "L")
        spelled.cards = ["SALES": ModelLayout.Card(x: 7, y: 9)]
        XCTAssertEqual(D.placements(model: model, layout: spelled).first?.card.x, 7)

        // "All tables" with one stored card: the others line up under it, left edges aligned.
        // Sales is 34 + 4 × 22 + 6 = 128 tall at y 300, so the row starts at 300 + 128 + 80 = 508.
        var all = ModelLayout(name: "All tables", showsAllTables: true)
        all.cards = ["Sales": ModelLayout.Card(x: 500, y: 300)]
        let placed = D.placements(model: model, layout: all)
        XCTAssertEqual(placed.map(\.table.name), ["Sales", "Product", "Date"], "model order")
        XCTAssertEqual(placed.map { CGPoint(x: $0.card.x, y: $0.card.y) },
                       [CGPoint(x: 500, y: 300), CGPoint(x: 500, y: 508), CGPoint(x: 780, y: 508)])
    }

    func testAllTablesWithNoStoredCardsIsAutoArranged() {
        var model = model()
        model.relationships = [relate("Sales", "ProductID", "Product", "ProductID"), relate("Sales", "OrderDate", "Date", "Date")]
        let scene = D.scene(model: model, layout: ModelLayout(name: "All tables", showsAllTables: true))
        // Product (84 tall) above, Sales (128) in the middle, Date (62) below; one card per row.
        XCTAssertEqual(scene.card("Product")?.frame, CGRect(x: 40, y: 40, width: 220, height: 84))
        XCTAssertEqual(scene.card("Sales")?.frame, CGRect(x: 40, y: 204, width: 220, height: 128), "40 + 84 + 80")
        XCTAssertEqual(scene.card("Date")?.frame, CGRect(x: 40, y: 412, width: 220, height: 62), "204 + 128 + 80")
        XCTAssertEqual(scene.bounds, CGRect(x: 40, y: 40, width: 220, height: 434))
        XCTAssertEqual(scene.edges.count, 2)
    }

    // MARK: Auto-arrange

    func testStarPutsTheFactInTheMiddleAndDimensionsAboveAndBelow() {
        let rels = [relate("Sales", "P", "Product", "P"), relate("Sales", "D", "Date", "D")]
        let out = D.autoArrange(tables: sized(["Sales", "Product", "Date"]), relationships: rels)
        XCTAssertEqual(out, ["Product": CGPoint(x: 40, y: 40), "Sales": CGPoint(x: 40, y: 220), "Date": CGPoint(x: 40, y: 450)],
                       "rows 100, 150 and 100 tall, 80 apart")
        // The same model declared the other way round (one-to-many from the dimension).
        let flipped = [relate("Product", "P", "Sales", "P", .oneToMany), relate("Date", "D", "Sales", "D", .oneToMany)]
        XCTAssertEqual(D.autoArrange(tables: sized(["Sales", "Product", "Date"]), relationships: flipped), out)
    }

    func testStarCentresRowsOnEachOther() {
        let names = ["Sales", "D1", "D2", "D3", "D4"]
        let rels = ["D1", "D2", "D3", "D4"].map { relate("Sales", $0, $0, "ID") }
        let out = D.autoArrange(tables: sized(names), relationships: rels)
        // Rows of two cards are 220 + 60 + 220 = 500 wide; the fact (220) is centred on them.
        XCTAssertEqual(out["D1"], CGPoint(x: 40, y: 40))
        XCTAssertEqual(out["D3"], CGPoint(x: 320, y: 40))
        XCTAssertEqual(out["Sales"], CGPoint(x: 180, y: 220))
        XCTAssertEqual(out["D2"], CGPoint(x: 40, y: 450))
        XCTAssertEqual(out["D4"], CGPoint(x: 320, y: 450))
    }

    func testSnowflakeTablesGoBeyondTheDimensionTheyHangOff() {
        let rels = [relate("Sales", "P", "Product", "P"), relate("Product", "C", "Category", "C")]
        let out = D.autoArrange(tables: sized(["Sales", "Product", "Category"]), relationships: rels)
        XCTAssertEqual(out, ["Category": CGPoint(x: 40, y: 40), "Product": CGPoint(x: 40, y: 220), "Sales": CGPoint(x: 40, y: 400)])
    }

    func testUnrelatedTablesLineUpUnderneathAndWrap() {
        let rels = [relate("Sales", "P", "Product", "P")]
        let out = D.autoArrange(tables: sized(["Sales", "Product", "Notes"]), relationships: rels)
        XCTAssertEqual(out, ["Product": CGPoint(x: 40, y: 40), "Sales": CGPoint(x: 40, y: 220), "Notes": CGPoint(x: 40, y: 450)])

        // No relationships at all: a grid, four to a row.
        let grid = D.autoArrange(tables: sized(["A", "B", "C", "D", "E"]), relationships: [])
        XCTAssertEqual(grid, ["A": CGPoint(x: 40, y: 40), "B": CGPoint(x: 320, y: 40), "C": CGPoint(x: 600, y: 40),
                              "D": CGPoint(x: 880, y: 40), "E": CGPoint(x: 40, y: 220)])
        XCTAssertEqual(D.autoArrange(tables: [], relationships: rels), [:])
    }

    func testWithoutAFactTableTheBusiestTableIsTheCentre() {
        // One-to-one has no many side: A (first of the tie) is the centre and B goes above it.
        let out = D.autoArrange(tables: sized(["A", "B"]), relationships: [relate("A", "K", "B", "K", .oneToOne)])
        XCTAssertEqual(out, ["B": CGPoint(x: 40, y: 40), "A": CGPoint(x: 40, y: 220)])
        // A chain where every table is on a one side somewhere: B has two relationships.
        let chain = [relate("A", "K", "B", "K"), relate("B", "K", "C", "K"), relate("C", "K", "A", "K")]
        let cyc = D.autoArrange(tables: sized(["A", "B", "C"]), relationships: chain)
        XCTAssertEqual(cyc["A"]?.y, 220, "A is first of the three-way tie, so it is the middle row")
    }

    func testAutoArrangeNeverOverlapsCards() {
        var names = ["Sales", "Returns"]
        var rels: [Relationship] = []
        for i in 1...9 {
            names.append("Dim\(i)")
            rels.append(relate(i % 2 == 0 ? "Sales" : "Returns", "K", "Dim\(i)", "K"))
        }
        rels.append(relate("Dim1", "K", "Sub1", "K"))
        names += ["Sub1", "Loose1", "Loose2", "Loose3", "Loose4", "Loose5"]
        let tables = names.enumerated().map { (name: $1, size: CGSize(width: 220, height: CGFloat(60 + 22 * ($0 % 7)))) }
        let out = D.autoArrange(tables: tables, relationships: rels)
        XCTAssertEqual(out.count, names.count, "every table is placed")
        let frames = tables.compactMap { t in out[t.name].map { CGRect(origin: $0, size: t.size) } }
        for i in frames.indices { for j in frames.indices where j > i {
            XCTAssertFalse(frames[i].intersects(frames[j]), "\(names[i]) overlaps \(names[j])")
        } }
        XCTAssertEqual(frames.map(\.minX).min(), 40)
        XCTAssertEqual(frames.map(\.minY).min(), 40)
        XCTAssertEqual(out["Sales"]?.y, out["Returns"]?.y, "both facts share the middle row")
        XCTAssertEqual(D.autoArrange(tables: tables, relationships: rels.reversed()), out, "relationship order does not matter")
    }

    // MARK: Hit-testing

    func testHitFindsTheHeaderToggleFieldsAndHandle() {
        let scene = D.scene(model: model(), layout: layout())
        // Sales: (40, 40) 220 × 128. Rows start at y 74: Amount, ProductID, OrderDate, Total.
        XCTAssertEqual(D.hit(CGPoint(x: 50, y: 50), in: scene), .header("Sales"))
        XCTAssertEqual(D.hit(CGPoint(x: 250, y: 50), in: scene), .toggle("Sales"), "the last 28 pt of the header")
        XCTAssertEqual(D.hit(CGPoint(x: 231, y: 50), in: scene), .header("Sales"))
        XCTAssertEqual(D.hit(CGPoint(x: 50, y: 75), in: scene), .field(table: "Sales", name: "Amount", kind: .column))
        XCTAssertEqual(D.hit(CGPoint(x: 50, y: 97), in: scene), .field(table: "Sales", name: "ProductID", kind: .column))
        XCTAssertEqual(D.hit(CGPoint(x: 50, y: 141), in: scene), .field(table: "Sales", name: "Total", kind: .measure))
        XCTAssertEqual(D.hit(CGPoint(x: 50, y: 165), in: scene), .card("Sales"), "the padding under the last row")
        XCTAssertEqual(D.hit(CGPoint(x: 255, y: 163), in: scene), .resize("Sales"), "12 pt corner")
        XCTAssertEqual(D.hit(CGPoint(x: 300, y: 50), in: scene), .canvas)
        XCTAssertEqual(D.hit(CGPoint(x: 410, y: 100), in: scene), .field(table: "Product", name: "Name", kind: .column))
        XCTAssertEqual(D.hit(CGPoint(x: 39, y: 50), in: scene), .canvas)
        XCTAssertEqual(D.Hit.field(table: "Sales", name: "Amount", kind: .column).table, "Sales")
        XCTAssertNil(D.Hit.canvas.table)
    }

    func testHitOnCollapsedAndOverflowingCards() {
        var layout = layout()
        layout.cards["Sales"]?.collapsed = true
        layout.cards["Product"]?.height = 70   // its two fields need 84; 70 leaves room for one row and the "more" row
        let scene = D.scene(model: model(), layout: layout)
        XCTAssertEqual(scene.card("Sales")?.frame.height, 34)
        XCTAssertEqual(D.hit(CGPoint(x: 255, y: 70), in: scene), .toggle("Sales"), "no resize handle on a collapsed card")
        XCTAssertEqual(D.hit(CGPoint(x: 100, y: 70), in: scene), .header("Sales"))
        XCTAssertEqual(D.hit(CGPoint(x: 50, y: 80), in: scene), .canvas)

        let product = scene.card("Product")
        XCTAssertEqual(product?.fields.map(\.name), ["ProductID"])
        XCTAssertEqual(product?.overflow, 1)
        XCTAssertEqual(product?.frame.height, 84, "34 + 22 + 22 + 6")
        XCTAssertEqual(D.hit(CGPoint(x: 410, y: 100), in: scene), .more("Product"), "the row after the one field")
    }

    func testTopMostCardWinsWhereCardsOverlap() {
        var layout = layout()
        layout.cards["Product"] = ModelLayout.Card(x: 100, y: 60)
        let point = CGPoint(x: 150, y: 70)   // Sales' header row… and Product's header
        XCTAssertEqual(D.hit(point, in: D.scene(model: model(), layout: layout)), .header("Product"), "later in model order is drawn on top")
        let front = D.scene(model: model(), layout: layout, front: "sales")
        XCTAssertEqual(front.cards.map(\.table), ["Product", "Sales"])
        XCTAssertEqual(D.hit(point, in: front), .header("Sales"))
    }

    // MARK: Lines

    func testRouteLeavesFacingSides() {
        let a = CGRect(x: 0, y: 0, width: 220, height: 100), b = CGRect(x: 400, y: 50, width: 220, height: 100)
        let right = D.route(from: a, fromY: nil, to: b, toY: nil)
        XCTAssertEqual(right.points, [CGPoint(x: 220, y: 50), CGPoint(x: 310, y: 50), CGPoint(x: 310, y: 100), CGPoint(x: 400, y: 100)])
        XCTAssertEqual(right.fromSide, .right)
        XCTAssertEqual(right.toSide, .left)
        XCTAssertEqual(D.route(from: a, fromY: 45, to: b, toY: 85).points.map(\.y), [45, 45, 85, 85], "column rows when they show")

        let left = D.route(from: b, fromY: nil, to: a, toY: nil)
        XCTAssertEqual(left.points, [CGPoint(x: 400, y: 100), CGPoint(x: 310, y: 100), CGPoint(x: 310, y: 50), CGPoint(x: 220, y: 50)])
        XCTAssertEqual(left.fromSide, .left)
        XCTAssertEqual(left.toSide, .right)
    }

    func testRouteBetweenStackedAndOverlappingCards() {
        let top = CGRect(x: 0, y: 0, width: 220, height: 100), bottom = CGRect(x: 0, y: 300, width: 220, height: 100)
        let down = D.route(from: top, fromY: 30, to: bottom, toY: 330)
        XCTAssertEqual(down.points, [CGPoint(x: 110, y: 100), CGPoint(x: 110, y: 200), CGPoint(x: 110, y: 200), CGPoint(x: 110, y: 300)])
        XCTAssertEqual(down.fromSide, .bottom)
        XCTAssertEqual(down.toSide, .top)
        let up = D.route(from: bottom, fromY: nil, to: top, toY: nil, lane: 0.5)
        XCTAssertEqual(up.points, [CGPoint(x: 118, y: 300), CGPoint(x: 118, y: 200), CGPoint(x: 118, y: 200), CGPoint(x: 118, y: 100)],
                       "half a lane is 8 pt to the right")
        XCTAssertEqual(up.fromSide, .top)

        // 20 pt apart horizontally is closer than the clearance: not a straight run between sides.
        let near = CGRect(x: 240, y: 300, width: 220, height: 100)
        XCTAssertEqual(D.route(from: top, fromY: nil, to: near, toY: nil).fromSide, .bottom)

        // Overlapping cards: out of both right sides and round.
        let over = CGRect(x: 100, y: 50, width: 220, height: 100)
        let loop = D.route(from: top, fromY: nil, to: over, toY: nil)
        XCTAssertEqual(loop.points, [CGPoint(x: 220, y: 50), CGPoint(x: 344, y: 50), CGPoint(x: 344, y: 100), CGPoint(x: 320, y: 100)])
        XCTAssertEqual(loop.toSide, .right)
    }

    func testEdgeAnchorsLabelsAndArrow() throws {
        var model = model()
        model.relationships = [relate("Sales", "ProductID", "Product", "ProductID")]
        let scene = D.scene(model: model, layout: layout())
        let edge = try XCTUnwrap(scene.edges.first)
        // Sales[ProductID] is row 1: y 40 + 34 + 22 + 11 = 107. Product[ProductID] is row 0: 40 + 34 + 11 = 85.
        XCTAssertEqual(edge.points, [CGPoint(x: 260, y: 107), CGPoint(x: 330, y: 107), CGPoint(x: 330, y: 85), CGPoint(x: 400, y: 85)])
        XCTAssertEqual(edge.fromLabel, "*")
        XCTAssertEqual(edge.toLabel, "1")
        XCTAssertEqual(edge.fromLabelPoint, CGPoint(x: 272, y: 98))
        XCTAssertEqual(edge.toLabelPoint, CGPoint(x: 388, y: 76))
        XCTAssertEqual(edge.direction, .towardFrom, "the one side filters the many side")
        XCTAssertTrue(edge.isActive)
        // 70 + 22 + 70 = 162 long; half way (81) is 11 up the middle segment.
        XCTAssertEqual(edge.arrowPoint, CGPoint(x: 330, y: 96))
        XCTAssertEqual(edge.arrowDirection, CGVector(dx: 0, dy: -1))
        XCTAssertEqual(edge.id, model.relationships[0].id)

        // Collapsed cards anchor at their middle (40 + 17).
        var collapsed = layout()
        collapsed.cards["Sales"]?.collapsed = true
        XCTAssertEqual(D.scene(model: model, layout: collapsed).edges.first?.points.first, CGPoint(x: 260, y: 57))
    }

    func testCardinalityLabelsAndFilterDirection() {
        XCTAssertEqual(D.endLabels(.manyToOne).from, "*"); XCTAssertEqual(D.endLabels(.manyToOne).to, "1")
        XCTAssertEqual(D.endLabels(.oneToMany).from, "1"); XCTAssertEqual(D.endLabels(.oneToMany).to, "*")
        XCTAssertEqual(D.endLabels(.oneToOne).from, "1"); XCTAssertEqual(D.endLabels(.oneToOne).to, "1")
        XCTAssertEqual(D.endLabels(.manyToMany).from, "*"); XCTAssertEqual(D.endLabels(.manyToMany).to, "*")

        var r = relate("Sales", "ProductID", "Product", "ProductID")
        XCTAssertEqual(D.filterDirection(r), .towardFrom)
        r.cardinality = .oneToMany
        XCTAssertEqual(D.filterDirection(r), .towardTo, "from is the one side now")
        r.crossFilter = .both
        XCTAssertEqual(D.filterDirection(r), .both)
    }

    func testEdgesSkipTablesNotOnTheLayoutAndSpreadParallelLines() {
        var model = model()
        var inactive = relate("Sales", "Amount", "Product", "ProductID")
        inactive.isActive = false
        model.relationships = [relate("Sales", "ProductID", "Product", "ProductID"), inactive, relate("Sales", "OrderDate", "Date", "Date")]
        XCTAssertEqual(D.scene(model: model, layout: layout()).edges.map(\.isActive), [true, false], "Date has no card on this layout")

        // Stacked cards: two lines between the same pair run 16 pt apart, centred on the cards.
        var stacked = layout()
        stacked.cards["Product"] = ModelLayout.Card(x: 40, y: 400)
        let edges = D.scene(model: model, layout: stacked).edges
        XCTAssertEqual(edges.map { $0.points.first?.x }, [142, 158], "150 ∓ 8")
        XCTAssertEqual(edges.map(\.fromSide), [.bottom, .bottom])
    }

    func testMidpointAndDistance() {
        let bend = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        XCTAssertEqual(D.midpoint(of: bend).point, CGPoint(x: 10, y: 0))
        XCTAssertEqual(D.midpoint(of: bend).direction, CGVector(dx: 1, dy: 0))
        XCTAssertEqual(D.midpoint(of: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 8)]).point, CGPoint(x: 0, y: 4))
        XCTAssertEqual(D.midpoint(of: [CGPoint(x: 3, y: 3)]).point, CGPoint(x: 3, y: 3))
        XCTAssertEqual(D.midpoint(of: []).point, .zero)

        XCTAssertEqual(D.distance(from: CGPoint(x: 5, y: 4), toPolyline: bend), 4)
        XCTAssertEqual(D.distance(from: CGPoint(x: 13, y: 14), toPolyline: bend), 5, "3-4-5 from the end")
        XCTAssertEqual(D.distance(from: CGPoint(x: 1, y: 1), toPolyline: []), .infinity)
    }

    func testHitOnALineWithinTolerance() throws {
        var model = model()
        model.relationships = [relate("Sales", "ProductID", "Product", "ProductID")]
        let scene = D.scene(model: model, layout: layout())
        let id = model.relationships[0].id
        XCTAssertEqual(D.hit(CGPoint(x: 300, y: 111), in: scene), .edge(id), "4 pt under the first run")
        XCTAssertEqual(D.hit(CGPoint(x: 300, y: 114), in: scene), .canvas, "7 pt away")
        XCTAssertEqual(D.hit(CGPoint(x: 300, y: 114), in: scene, tolerance: 12), .edge(id), "zoomed out: a wider reach in canvas points")
        XCTAssertEqual(D.hit(CGPoint(x: 258, y: 107), in: scene), .field(table: "Sales", name: "ProductID", kind: .column), "cards come first")
    }

    // MARK: Validation

    func testDropProblemCoversSameTableDuplicateAndTypeMismatch() {
        var model = model()
        XCTAssertNil(D.dropProblem(model: model, fromTable: "Sales", fromColumn: "ProductID", toTable: "Product", toColumn: "ProductID"))
        XCTAssertNil(D.dropProblem(model: model, fromTable: "Sales", fromColumn: "Amount", toTable: "Product", toColumn: "ProductID"),
                     "decimal and whole number are both numbers")
        XCTAssertEqual(D.dropProblem(model: model, fromTable: "Sales", fromColumn: "Amount", toTable: "sales", toColumn: "ProductID"),
                       "A relationship needs two different tables.")
        let mismatch = D.dropProblem(model: model, fromTable: "Sales", fromColumn: "ProductID", toTable: "Product", toColumn: "Name")
        XCTAssertEqual(mismatch?.contains("matching data types"), true)
        XCTAssertNotNil(D.dropProblem(model: model, fromTable: "Sales", fromColumn: "OrderDate", toTable: "Product", toColumn: "ProductID"), "date to number")
        XCTAssertNotNil(D.dropProblem(model: model, fromTable: "Sales", fromColumn: "Gone", toTable: "Product", toColumn: "ProductID"))

        model.relationships = [relate("Sales", "ProductID", "Product", "ProductID")]
        XCTAssertEqual(D.dropProblem(model: model, fromTable: "Sales", fromColumn: "ProductID", toTable: "Product", toColumn: "ProductID"),
                       "These two columns are already related.")
        XCTAssertEqual(D.dropProblem(model: model, fromTable: "Product", fromColumn: "productid", toTable: "Sales", toColumn: "ProductID"),
                       "These two columns are already related.", "dragged the other way")
    }

    func testRelationshipEditValidation() {
        var model = model()
        let active = relate("Sales", "ProductID", "Product", "ProductID")
        var second = relate("Sales", "Amount", "Product", "ProductID")
        second.isActive = false
        model.relationships = [active, second]

        XCTAssertNil(RelationshipLogic.updateProblem(second, model: model), "inactive is fine")
        var activated = second
        activated.isActive = true
        XCTAssertNotNil(RelationshipLogic.updateProblem(activated, model: model), "Sales and Product are already connected")
        var changed = active
        changed.cardinality = .manyToMany
        XCTAssertNil(RelationshipLogic.updateProblem(changed, model: model), "its own path does not count against it")
        var retyped = active
        retyped.toColumn = "Name"
        XCTAssertNotNil(RelationshipLogic.updateProblem(retyped, model: model))
        var duplicate = second
        duplicate.fromColumn = "ProductID"
        XCTAssertEqual(RelationshipLogic.updateProblem(duplicate, model: model), "These two columns are already related.")
    }

    func testRelationshipSwapNormalizeAndRetarget() {
        let model = model()
        let r = relate("Sales", "ProductID", "Product", "ProductID")
        let swapped = RelationshipLogic.swapped(r)
        XCTAssertEqual([swapped.fromTable, swapped.fromColumn, swapped.toTable, swapped.toColumn], ["Product", "ProductID", "Sales", "ProductID"])
        XCTAssertEqual(swapped.cardinality, .oneToMany, "Sales is still the many side")
        XCTAssertEqual(RelationshipLogic.swapped(swapped).cardinality, .manyToOne)
        XCTAssertEqual(swapped.id, r.id)

        var oneToOne = r
        oneToOne.cardinality = .oneToOne
        XCTAssertEqual(RelationshipLogic.normalized(oneToOne).crossFilter, .both)
        var single = r
        single.securityFilterBothDirections = true
        XCTAssertFalse(RelationshipLogic.normalized(single).securityFilterBothDirections, "only meaningful when filtering both ways")
        single.crossFilter = .both
        XCTAssertTrue(RelationshipLogic.normalized(single).securityFilterBothDirections)

        // The "to" table changed to Date: ProductID is not there; the first compatible column
        // for a whole number… Date has only a date column, so it is left to be chosen.
        var moved = r
        moved.toTable = "Date"
        XCTAssertEqual(RelationshipLogic.retargeted(moved, model: model).toColumn, "")
        // The "from" table changed to Product: the like-named column is taken.
        var from = relate("Sales", "ProductID", "Date", "Date")
        from.fromTable = "Product"
        XCTAssertEqual(RelationshipLogic.retargeted(from, model: model).fromColumn, "ProductID")
        // Changed to Sales with a date on the other end: the first date column.
        var dated = relate("Product", "Name", "Date", "Date")
        dated.fromTable = "Sales"
        XCTAssertEqual(RelationshipLogic.retargeted(dated, model: model).fromColumn, "OrderDate")
        XCTAssertEqual(RelationshipLogic.retargeted(r, model: model), r, "nothing to fix")
    }

    // MARK: Card edits and viewport

    func testMoveAndResizeCards() {
        let card = ModelLayout.Card(x: 40, y: 40)
        let moved = D.moved(card, by: CGSize(width: 25, height: -10))
        XCTAssertEqual(moved.x, 65); XCTAssertEqual(moved.y, 30)
        let smaller = D.resized(card, from: CGSize(width: 220, height: 106), by: CGSize(width: -200, height: -100))
        XCTAssertEqual(smaller.width, 160)
        XCTAssertEqual(smaller.height, 84, "one row and the more row: 34 + 22 + 22 + 6")
        let bigger = D.resized(card, from: CGSize(width: 220, height: 106), by: CGSize(width: 500, height: 50))
        XCTAssertEqual(bigger.width, 480); XCTAssertEqual(bigger.height, 156)
        XCTAssertEqual(bigger.x, 40, "resizing keeps the corner in place")
    }

    func testFitCentresTheDiagramAndNeverZoomsIn() {
        let bounds = CGRect(x: 40, y: 40, width: 440, height: 560)
        let roomy = D.fit(bounds, in: CGSize(width: 1000, height: 800))
        XCTAssertEqual(roomy.zoom, 1)
        XCTAssertEqual(roomy.offset, CGSize(width: 240, height: 80), "(1000 − 440) / 2 − 40 and (800 − 560) / 2 − 40")
        // 300 × 400 leaves 220 × 320: 220 / 440 = 0.5 is the tighter fit.
        let tight = D.fit(bounds, in: CGSize(width: 300, height: 400))
        XCTAssertEqual(tight.zoom, 0.5)
        XCTAssertEqual(tight.offset, CGSize(width: 20, height: 40))
        XCTAssertEqual(tight.toScreen(CGPoint(x: 40, y: 40)), CGPoint(x: 40, y: 60), "the diagram's corner, inside the padding")
        XCTAssertEqual(D.fit(.zero, in: CGSize(width: 300, height: 400)), D.Viewport())
        XCTAssertEqual(D.fit(bounds, in: .zero), D.Viewport())
        XCTAssertEqual(D.fit(CGRect(x: 0, y: 0, width: 100_000, height: 10), in: CGSize(width: 500, height: 500)).zoom, 0.25, "the floor")
    }

    func testZoomKeepsThePointUnderThePointer() {
        let start = D.Viewport(zoom: 1, offset: .zero)
        let anchor = CGPoint(x: 100, y: 100)
        let zoomed = D.zoomed(start, by: 2, around: anchor)
        XCTAssertEqual(zoomed.zoom, 2)
        XCTAssertEqual(zoomed.offset, CGSize(width: -100, height: -100))
        XCTAssertEqual(zoomed.toCanvas(anchor), start.toCanvas(anchor))
        XCTAssertEqual(D.zoomed(start, by: 10, around: anchor).zoom, 2, "capped")
        XCTAssertEqual(D.zoomed(start, by: 0.01, around: anchor).zoom, 0.25)
        let v = D.Viewport(zoom: 0.5, offset: CGSize(width: 30, height: -20))
        XCTAssertEqual(v.toScreen(CGPoint(x: 100, y: 200)), CGPoint(x: 80, y: 80))
        XCTAssertEqual(v.toCanvas(CGPoint(x: 80, y: 80)), CGPoint(x: 100, y: 200))
    }

    // MARK: Layout tabs

    func testLayoutTabsNamesAndRemoval() {
        var model = model()
        XCTAssertEqual(ModelLayouts.tabs(model).map(\.name), ["All tables"])
        XCTAssertEqual(ModelLayouts.nextName(model), "Layout 1")
        let first = ModelLayouts.add(to: &model)
        XCTAssertEqual(ModelLayouts.nextName(model), "Layout 2")
        let second = ModelLayouts.add(to: &model, name: "Finance")
        XCTAssertEqual(ModelLayouts.tabs(model).map(\.name), ["All tables", "Layout 1", "Finance"])
        XCTAssertEqual(ModelLayouts.current(model, id: second).name, "Finance")
        XCTAssertTrue(ModelLayouts.current(model, id: nil).showsAllTables)
        XCTAssertTrue(ModelLayouts.current(model, id: UUID()).showsAllTables, "an unknown id falls back")

        XCTAssertNil(ModelLayouts.renameProblem(model, id: first, to: "Sales area"))
        XCTAssertNil(ModelLayouts.renameProblem(model, id: first, to: "layout 1"), "its own name, recased")
        XCTAssertNotNil(ModelLayouts.renameProblem(model, id: first, to: "finance"))
        XCTAssertNotNil(ModelLayouts.renameProblem(model, id: first, to: "   "))

        XCTAssertTrue(ModelLayouts.remove(from: &model, id: first))
        XCTAssertEqual(ModelLayouts.nextName(model), "Layout 1", "the name is free again")
        let all = ModelLayouts.current(model, id: nil).id
        XCTAssertFalse(ModelLayouts.remove(from: &model, id: all), "All tables stays")
        XCTAssertFalse(ModelLayouts.remove(from: &model, id: UUID()))

        // A model that arrived without layouts still has something to draw, and to edit.
        model.layouts = []
        let synthesised = ModelLayouts.current(model, id: nil)
        XCTAssertTrue(synthesised.showsAllTables)
        XCTAssertEqual(ModelLayouts.tabs(model).count, 1)
        XCTAssertEqual(ModelLayouts.index(of: synthesised, in: &model), 0)
        XCTAssertEqual(model.layouts.map(\.id), [synthesised.id])
    }

    func testAddingTablesToAUserLayout() throws {
        var model = model()
        model.relationships = [relate("Sales", "ProductID", "Product", "ProductID"), relate("Sales", "OrderDate", "Date", "Date")]
        var layout = ModelLayout(name: "L")
        XCTAssertEqual(ModelLayouts.addable(model, layout: layout).map(\.name), ["Sales", "Product", "Date"])
        XCTAssertEqual(ModelLayouts.slot(for: model.tables[0], in: layout, model: model), CGPoint(x: 40, y: 40), "an empty layout starts at the padding")
        ModelLayouts.setCard(ModelLayout.Card(x: 40, y: 40), for: "Sales", in: &layout)
        XCTAssertEqual(ModelLayouts.addable(model, layout: layout).map(\.name), ["Product", "Date"])
        XCTAssertEqual(ModelLayouts.relatedMissing(model, layout: layout, table: "sales").map(\.name), ["Product", "Date"])
        XCTAssertEqual(ModelLayouts.relatedMissing(model, layout: layout, table: "Product").map(\.name), [], "Sales is already there")
        XCTAssertEqual(ModelLayouts.slot(for: model.tables[1], in: layout, model: model), CGPoint(x: 320, y: 40), "40 + 220 + 60")
        XCTAssertEqual(ModelLayouts.addable(model, layout: ModelLayout(name: "All", showsAllTables: true)).count, 0)

        // One card per table, whatever the spelling.
        layout.cards = ["SALES": ModelLayout.Card(x: 1, y: 1)]
        ModelLayouts.setCard(ModelLayout.Card(x: 9, y: 9), for: "Sales", in: &layout)
        XCTAssertEqual(Array(layout.cards.keys), ["Sales"])
        XCTAssertEqual(layout.cards["Sales"]?.x, 9)
    }

    func testArrangedKeepsEachCardsSizeAndState() throws {
        var model = model()
        model.relationships = [relate("Sales", "ProductID", "Product", "ProductID")]
        var layout = layout()
        layout.cards["Product"]?.collapsed = true
        layout.cards["Sales"]?.width = 300
        let cards = ModelLayouts.arranged(model, layout: layout)
        // Product (collapsed, 220 × 34) above Sales (300 × 128), centred: Product is 40 pt in.
        XCTAssertEqual(cards["Product"]?.x, 80); XCTAssertEqual(cards["Product"]?.y, 40)
        XCTAssertEqual(cards["Sales"]?.x, 40); XCTAssertEqual(cards["Sales"]?.y, 154, "40 + 34 + 80")
        XCTAssertEqual(cards["Product"]?.collapsed, true)
        XCTAssertEqual(cards["Sales"]?.width, 300)
        XCTAssertNil(cards["Date"], "not on this layout")
    }

    // MARK: Properties and explorer

    func testPropertiesHelpers() {
        XCTAssertEqual(ModelProperties.synonyms(from: " revenue, Turnover ,,revenue , "), ["revenue", "Turnover"])
        XCTAssertEqual(ModelProperties.synonyms(from: ""), [])
        let selection: [ModelObjectRef] = [.column(table: "Sales", name: "Amount"), .table("Sales"), .column(table: "Sales", name: "ProductID")]
        XCTAssertEqual(ModelProperties.targets(selection), [.column(table: "Sales", name: "Amount"), .column(table: "Sales", name: "ProductID")],
                       "the objects of the primary object's kind")
        XCTAssertEqual(ModelProperties.targets([]), [])
        let role = ModelObjectRef.role(UUID())
        XCTAssertEqual(ModelProperties.targets([.table("Sales"), role]), [role])
        XCTAssertEqual(ModelProperties.shared(["a", "a"]), "a")
        XCTAssertNil(ModelProperties.shared(["a", "b"]))
        XCTAssertNil(ModelProperties.shared([String]()))
    }

    func testExplorerSectionsAndSearch() throws {
        var model = model()
        var r = relate("Sales", "ProductID", "Product", "ProductID")
        r.isActive = false
        model.relationships = [r]
        model.roles = [SecurityRole(name: "West")]
        model.tables[0].hierarchies = [Hierarchy(name: "Calendar", levels: ["OrderDate"])]

        let sections = ModelExplorerItems.sections(model)
        XCTAssertEqual(sections.map(\.title), ["Tables", "Relationships", "Roles"], "empty sections are left out")
        let sales = try XCTUnwrap(sections[0].items.first)
        XCTAssertEqual(sales.children.map(\.title), ["Amount", "ProductID", "OrderDate", "Total", "Calendar"])
        XCTAssertEqual(sections[1].items.map(\.title), ["Sales[ProductID] → Product[ProductID]"])
        XCTAssertEqual(sections[1].items.first?.isHidden, true, "inactive")

        let found = ModelExplorerItems.sections(model, search: "  productid ")
        XCTAssertEqual(found.map(\.title), ["Tables", "Relationships"])
        XCTAssertEqual(found[0].items.map(\.title), ["Sales", "Product"], "Date has no match")
        XCTAssertEqual(found[0].items[0].children.map(\.title), ["ProductID"], "only the matching fields")
        let byTable = ModelExplorerItems.sections(model, search: "sales")
        XCTAssertEqual(byTable[0].items.first?.children.count, 5, "a matching table keeps all its fields")
        XCTAssertTrue(ModelExplorerItems.sections(model, search: "zzz").isEmpty)

        XCTAssertEqual(ModelExplorerItems.caption(for: .column(table: "sales", name: "amount"), in: model), "Amount")
        XCTAssertEqual(ModelExplorerItems.caption(for: .relationship(r.id), in: model), "Sales[ProductID] → Product[ProductID]")
        XCTAssertNil(ModelExplorerItems.caption(for: .table("Gone"), in: model))
    }
}
