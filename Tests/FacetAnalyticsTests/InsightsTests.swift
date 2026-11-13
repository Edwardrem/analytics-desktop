import XCTest
import FacetCore
@testable import FacetAnalytics

final class InsightsTests: XCTestCase {
    // MARK: Clustering

    static func blobs(seed: UInt64 = 1, perCluster: Int = 40) -> (points: [[Double]], truth: [Int]) {
        var rng = SeededGenerator(seed: seed)
        let centres: [[Double]] = [[0, 0], [10, 0], [5, 900]] // second axis on a very different scale
        var pts: [[Double]] = [], truth: [Int] = []
        for i in 0..<(perCluster * 3) {
            let c = i % 3
            pts.append([centres[c][0] + rng.normal() * 0.6, centres[c][1] + rng.normal() * 60])
            truth.append(c)
        }
        return (pts, truth)
    }

    func testKMeansRecoversBlobsAndChoosesK() throws {
        let (pts, truth) = Self.blobs()
        let r = try KMeans.cluster(points: pts)
        XCTAssertEqual(r.k, 3)
        XCTAssertGreaterThan(r.silhouette, 0.6)
        XCTAssertEqual(r.sizes, [40, 40, 40])
        // Every true blob maps to exactly one cluster.
        for c in 0..<3 {
            let labels = Set(pts.indices.filter { truth[$0] == c }.map { r.assignments[$0] })
            XCTAssertEqual(labels.count, 1)
        }
        XCTAssertEqual(Set(r.assignments).count, 3)
        // Centroids are reported in original units.
        let cx = r.centroids.map { $0[0] }.sorted()
        XCTAssertEqual(cx[0], 0, accuracy: 0.5); XCTAssertEqual(cx[1], 5, accuracy: 0.5); XCTAssertEqual(cx[2], 10, accuracy: 0.5)
        // Deterministic.
        let again = try KMeans.cluster(points: pts)
        XCTAssertEqual(again.assignments, r.assignments)
        // Fixed k is honoured.
        let two = try KMeans.cluster(points: pts, k: 2)
        XCTAssertEqual(two.k, 2); XCTAssertEqual(two.centroids.count, 2)
        XCTAssertLessThan(two.silhouette, r.silhouette)
        XCTAssertThrowsError(try KMeans.cluster(points: [[1]])) { XCTAssertNotNil(($0 as? LocalizedError)?.errorDescription) }
        XCTAssertThrowsError(try KMeans.cluster(points: [[1, 2], [1]]))
    }

    func testDBSCANAndTableClustering() throws {
        var (pts, truth) = Self.blobs(seed: 4)
        pts.append([5, 400]); truth.append(-1) // isolated noise point
        let r = try DBSCAN.cluster(points: pts, eps: 0.6, minPoints: 4)
        XCTAssertEqual(r.k, 3)
        XCTAssertEqual(r.assignments.last, -1)
        for c in 0..<3 {
            let labels = Set(pts.indices.filter { truth[$0] == c }.map { r.assignments[$0] }).subtracting([-1])
            XCTAssertEqual(labels.count, 1)
        }
        let auto = try DBSCAN.cluster(points: pts)
        XCTAssertGreaterThanOrEqual(auto.k, 2)

        var rows: [[Value]] = pts.prefix(120).map { [.double($0[0]), .double($0[1])] }
        rows.insert([.null, 3.0], at: 5)
        let t = DataTable(columnNames: ["x", "y"], rows: rows)
        let (assign, res) = try Clustering.cluster(table: t, columns: ["x", "y"])
        XCTAssertNil(assign[5])
        XCTAssertEqual(res.k, 3)
        XCTAssertEqual(assign.compactMap { $0 }.count, 120)
        XCTAssertThrowsError(try Clustering.cluster(table: t, columns: ["missing"]))
    }

    // MARK: Key influencers

    /// Churn data: Plan = Basic and many support tickets drive churn; Region and Noise do nothing.
    static func churnTable(n: Int = 2400, seed: UInt64 = 17) -> DataTable {
        var rng = SeededGenerator(seed: seed)
        var rows: [[Value]] = []
        let plans = ["Basic", "Pro", "Enterprise"], regions = ["North", "South", "East", "West"]
        for i in 0..<n {
            let plan = plans[i % 3], region = regions[Int(rng.unit() * 4) % 4]
            let tickets = (rng.unit() * 10).rounded(.down) + rng.unit()
            let noise = rng.normal() * 5 + 50
            var p = 0.06 + 0.04 * tickets
            if plan == "Basic" { p += 0.35 }
            rows.append([.string(plan), .string(region), .double(tickets), .double(noise), .string(rng.unit() < p ? "Yes" : "No")])
        }
        return DataTable(columnNames: ["Plan", "Region", "Tickets", "Noise", "Churned"], rows: rows)
    }

    func testKeyInfluencersCategoricalTarget() throws {
        let t = Self.churnTable()
        let r = try KeyInfluencers.analyze(table: t, target: "Churned", targetValue: "Yes", explainBy: ["Plan", "Region", "Tickets", "Noise"])
        XCTAssertEqual(r.targetKind, .categorical)
        XCTAssertEqual(r.rowCount, 2400)
        XCTAssertGreaterThan(r.baseline, 0.2); XCTAssertLessThan(r.baseline, 0.55)
        let top = try XCTUnwrap(r.influencers.first)
        XCTAssertEqual(top.factor, "Plan")
        XCTAssertEqual(top.kind, .category("Basic"))
        let mult = try XCTUnwrap(top.multiplier)
        XCTAssertGreaterThan(mult, 1.8); XCTAssertLessThan(mult, 3.5) // true ratio ≈ 0.59 / 0.24
        XCTAssertLessThan(top.pValue, 1e-6)
        XCTAssertTrue(top.sentence.contains("Basic") && top.sentence.contains("x"))
        XCTAssertEqual(top.distribution.count, 3)
        XCTAssertEqual(top.distribution.filter(\.isHighlighted).map(\.label), ["Basic"])
        // The numeric driver is reported per standard deviation, going up.
        let tickets = try XCTUnwrap(r.influencers.first { $0.factor == "Tickets" })
        guard case .perUnit(let amount, let increase) = tickets.kind else { return XCTFail("expected per-unit influencer") }
        XCTAssertTrue(increase)
        XCTAssertEqual(amount, 2.9, accuracy: 0.3)
        XCTAssertGreaterThan(try XCTUnwrap(tickets.multiplier), 1.1)
        XCTAssertEqual(tickets.distribution.count, 5)
        // Non-influencers are not reported.
        XCTAssertFalse(r.influencers.contains { $0.factor == "Region" })
        XCTAssertFalse(r.influencers.contains { $0.factor == "Noise" })
        XCTAssertFalse(r.influencers.contains { $0.kind == .category("Pro") || $0.kind == .category("Enterprise") })
    }

    func testKeyInfluencersContinuousTarget() throws {
        var rng = SeededGenerator(seed: 23)
        var rows: [[Value]] = []
        for i in 0..<900 {
            let garage = i % 3 == 0 ? "Yes" : "No"
            let rooms = Double(2 + i % 9) + rng.unit()
            let colour = ["Red", "Blue", "Green"][Int(rng.unit() * 3) % 3]
            let price = 100 + (garage == "Yes" ? 50 : 0) + 10 * rooms + rng.normal() * 8
            rows.append([.string(garage), .double(rooms), .string(colour), .double(price)])
        }
        let t = DataTable(columnNames: ["Garage", "Rooms", "Colour", "Price"], rows: rows)
        let up = try KeyInfluencers.analyze(table: t, target: "Price", explainBy: ["Garage", "Rooms", "Colour"])
        XCTAssertEqual(up.targetKind, .continuous)
        XCTAssertEqual(up.influencers.first?.factor, "Garage")
        XCTAssertEqual(up.influencers.first?.kind, .category("Yes"))
        XCTAssertEqual(try XCTUnwrap(up.influencers.first?.difference), 50, accuracy: 4)
        let rooms = try XCTUnwrap(up.influencers.first { $0.factor == "Rooms" })
        // slope 10 × sd(rooms) ≈ 10 × 2.6
        XCTAssertEqual(try XCTUnwrap(rooms.difference), 26, accuracy: 3)
        XCTAssertFalse(up.influencers.contains { $0.factor == "Colour" })
        XCTAssertTrue(up.influencers[0].sentence.contains("increases"))

        let down = try KeyInfluencers.analyze(table: t, target: "Price", direction: .decrease, explainBy: ["Garage", "Rooms", "Colour"])
        XCTAssertEqual(down.influencers.first?.kind, .category("No"))
        XCTAssertLessThan(try XCTUnwrap(down.influencers.first?.difference), -40)
        let roomsDown = try XCTUnwrap(down.influencers.first { $0.factor == "Rooms" })
        guard case .perUnit(_, let increase) = roomsDown.kind else { return XCTFail() }
        XCTAssertFalse(increase)

        XCTAssertThrowsError(try KeyInfluencers.analyze(table: t, target: "Nope", explainBy: ["Garage"])) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "The column “Nope” was not found in the data.")
        }
        XCTAssertThrowsError(try KeyInfluencers.analyze(table: t.prefix(5), target: "Price", explainBy: ["Garage"]))
    }

    func testTopSegments() throws {
        // Planted segment: Plan = Basic AND Tickets > 6 churns at 85%; everyone else at 8%.
        var rng = SeededGenerator(seed: 31)
        var rows: [[Value]] = []
        for i in 0..<2000 {
            let plan = ["Basic", "Pro", "Enterprise"][i % 3]
            let tickets = (rng.unit() * 10).rounded(.down)
            let region = ["N", "S"][Int(rng.unit() * 2) % 2]
            let p = (plan == "Basic" && tickets > 6) ? 0.85 : 0.08
            rows.append([.string(plan), .double(tickets), .string(region), .bool(rng.unit() < p)])
        }
        let t = DataTable(columnNames: ["Plan", "Tickets", "Region", "Churned"], rows: rows)
        var opts = KeyInfluencers.Options(); opts.maxCategoricalDistinct = 5
        let r = try KeyInfluencers.analyze(table: t, target: "Churned", targetValue: true, explainBy: ["Plan", "Tickets", "Region"], options: opts)
        let seg = try XCTUnwrap(r.segments.first)
        XCTAssertGreaterThan(seg.value, 0.75)
        XCTAssertGreaterThan(seg.lift, 4)
        XCTAssertTrue(seg.predicates.contains(SegmentPredicate(column: "Plan", op: .equals, value: "Basic")))
        let ticketPred = try XCTUnwrap(seg.predicates.first { $0.column == "Tickets" })
        XCTAssertEqual(ticketPred.op, .greaterThan)
        XCTAssertEqual(try XCTUnwrap(ticketPred.value.asDouble), 6, accuracy: 0.01)
        XCTAssertFalse(seg.predicates.contains { $0.column == "Region" })
        XCTAssertEqual(Double(seg.size), 2000.0 / 3 * 0.3, accuracy: 40)
        XCTAssertEqual(seg.share, Double(seg.size) / 2000, accuracy: 1e-12)
        XCTAssertTrue(seg.sentence.contains("Plan is Basic"))
        XCTAssertLessThanOrEqual(seg.predicates.count, 4)
        XCTAssertEqual(ticketPred.filter(table: "T").conditions.first?.op, .greaterThan)
        // Redundant conditions collapse.
        let simplified = SegmentFinder.simplify([
            SegmentPredicate(column: "A", op: .greaterThan, value: 2), SegmentPredicate(column: "B", op: .notEquals, value: "x"),
            SegmentPredicate(column: "A", op: .greaterThan, value: 5), SegmentPredicate(column: "B", op: .equals, value: "y"),
        ])
        XCTAssertEqual(simplified, [SegmentPredicate(column: "A", op: .greaterThan, value: 5), SegmentPredicate(column: "B", op: .equals, value: "y")])
    }

    // MARK: Decomposition tree

    static let region = FieldRef.column("Sales", "Region"), product = FieldRef.column("Sales", "Product"), channel = FieldRef.column("Sales", "Channel")

    static func salesTable() -> DataTable {
        // Channel totals are large but similar; Product "Gizmo" dwarfs other products; Region "South" is tiny.
        var rows: [[Value]] = []
        let products = ["Gizmo", "Widget", "Gadget", "Doohickey"], regions = ["North", "South", "East", "West"], channels = ["Web", "Store"]
        for (pi, p) in products.enumerated() {
            for (ri, r) in regions.enumerated() {
                for (ci, c) in channels.enumerated() {
                    var v = 100.0 + Double(pi * 7 + ri * 3 + ci * 5)
                    if p == "Gizmo" { v *= 6 }
                    if r == "South" { v *= 0.1 }
                    rows.append([.string(r), .string(p), .string(c), .double(v)])
                }
            }
        }
        return DataTable(columnNames: ["Region", "Product", "Channel", "Amount"], rows: rows)
    }

    func testDecompositionTree() throws {
        let t = Self.salesTable()
        let tree = DecompositionTree(dimensions: [Self.region, Self.product, Self.channel], query: InMemoryQuery.make(table: t, measure: "Amount"))
        let total = try XCTUnwrap(tree.value())
        XCTAssertEqual(total, t.columns[3].values.compactMap(\.asDouble).reduce(0, +), accuracy: 1e-9)

        let byRegion = tree.children(by: Self.region)
        XCTAssertEqual(byRegion.children.count, 4)
        XCTAssertEqual(byRegion.children.last?.value, "South")
        XCTAssertEqual(byRegion.children.compactMap(\.share).reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(byRegion.children.map(\.amount), byRegion.children.map(\.amount).sorted(by: >))

        // Absolute high value: Gizmo has the biggest single total of any member of any candidate field.
        let abs = try XCTUnwrap(tree.aiSplit(kind: .highValue, mode: .absolute))
        XCTAssertEqual(abs.dimension.name, "Product")
        XCTAssertEqual(abs.highlightedIndex, 0)
        // Relative high value: Gizmo stands out most from its peers.
        let rel = try XCTUnwrap(tree.aiSplit(kind: .highValue, mode: .relative))
        XCTAssertEqual(rel.dimension.name, "Product")
        XCTAssertEqual(rel.children.first?.value, "Gizmo")
        XCTAssertEqual(rel.children.count, 4)
        XCTAssertTrue(rel.explanation.contains("Gizmo"))
        // Low value: South is the smallest member anywhere.
        let low = try XCTUnwrap(tree.aiSplit(kind: .lowValue))
        XCTAssertEqual(low.dimension.name, "Region")
        XCTAssertEqual(low.children.first?.value, "South")
        XCTAssertEqual(low.split, .lowValue)

        // Expanding under Gizmo: remaining dimensions only, values filtered to the path.
        let path = [try XCTUnwrap(rel.children.first).step]
        XCTAssertEqual(tree.availableDimensions(for: path).map(\.name), ["Region", "Channel"])
        let under = tree.children(of: path, by: Self.region)
        XCTAssertEqual(under.children.reduce(0) { $0 + $1.amount }, try XCTUnwrap(tree.value(at: path)), accuracy: 1e-9)
        let next = try XCTUnwrap(tree.aiSplit(path: path, kind: .lowValue))
        XCTAssertEqual(next.children.first?.value, "South")
        XCTAssertNil(tree.aiSplit(path: path, kind: .highValue, candidates: []))
    }

    // MARK: Explain the change

    func testChangeExplainer() throws {
        // Jan → Feb: West jumps by 500, other regions flat; products each move a little.
        var rows: [[Value]] = []
        let regions = ["North", "South", "East", "West"], products = ["A", "B", "C", "D", "E"]
        for month in ["Jan", "Feb"] {
            for r in regions {
                for p in products {
                    var v = 100.0
                    if month == "Feb" && r == "West" { v += 100 }
                    rows.append([.string(month), .string(r), .string(p), .double(v)])
                }
            }
        }
        let t = DataTable(columnNames: ["Month", "Region", "Product", "Amount"], rows: rows)
        let month = FieldRef.column("Sales", "Month")
        var before = FilterSpec(field: month, kind: .basic); before.values = ["Jan"]
        var after = FilterSpec(field: month, kind: .basic); after.values = ["Feb"]
        let r = ChangeExplainer.explain(before: [before], after: [after], dimensions: [Self.product, Self.region],
                                        query: InMemoryQuery.make(table: t, measure: "Amount"))
        XCTAssertEqual(r.before, 2000); XCTAssertEqual(r.after, 2500); XCTAssertEqual(r.delta, 500)
        XCTAssertTrue(r.isIncrease)
        XCTAssertEqual(r.explanations.count, 2)
        let best = r.explanations[0]
        XCTAssertEqual(best.dimension.name, "Region")
        XCTAssertEqual(best.score, 1, accuracy: 1e-9)
        XCTAssertEqual(best.contributions[0].member, "West")
        XCTAssertEqual(best.contributions[0].change, 500)
        XCTAssertEqual(best.contributions[0].shareOfDelta, 1)
        XCTAssertTrue(best.sentence.contains("West") && best.sentence.contains("100%") && best.sentence.contains("increase"))
        XCTAssertEqual(r.explanations[1].score, 0, accuracy: 1e-9) // spread evenly over products
        // Waterfall adds up.
        let w = best.waterfall
        XCTAssertEqual(w.start + w.contributions.reduce(0) { $0 + $1.change } + w.other, w.end, accuracy: 1e-9)
        let capped = ChangeExplainer.explain(before: [before], after: [after], dimensions: [Self.product],
                                             query: InMemoryQuery.make(table: t, measure: "Amount"), maxContributors: 2)
        XCTAssertEqual(capped.explanations[0].waterfall.contributions.count, 2)
        XCTAssertEqual(capped.explanations[0].waterfall.other, 300, accuracy: 1e-9)
        // Decrease wording.
        let rev = ChangeExplainer.explain(before: [after], after: [before], dimensions: [Self.region], query: InMemoryQuery.make(table: t, measure: "Amount"))
        XCTAssertFalse(rev.isIncrease)
        XCTAssertTrue(rev.explanations[0].sentence.contains("decrease"))
    }

    // MARK: Distribution difference

    func testDistributionDifference() throws {
        // Product mix is even everywhere except Region = South, where product A dominates.
        var rows: [[Value]] = []
        for r in ["North", "South", "East", "West"] {
            for c in ["Web", "Store"] {
                for p in ["A", "B", "C"] {
                    var v = 100.0
                    if r == "South" { v = p == "A" ? 240 : 30 }
                    rows.append([.string(r), .string(c), .string(p), .double(v)])
                }
            }
        }
        let t = DataTable(columnNames: ["Region", "Channel", "Product", "Amount"], rows: rows)
        let slices = DistributionDifference.find(category: Self.product, dimensions: [Self.channel, Self.region, Self.product],
                                                 query: InMemoryQuery.make(table: t, measure: "Amount"))
        let top = try XCTUnwrap(slices.first)
        XCTAssertEqual(top.dimension.name, "Region")
        XCTAssertEqual(top.value, "South")
        XCTAssertEqual(top.shares.map(\.category), ["A", "B", "C"])
        XCTAssertEqual(top.shares[0].slice, 0.8, accuracy: 1e-12)
        // Overall product mix: South holds 480 of the 1080 that product A totals everywhere.
        XCTAssertEqual(top.shares[0].overall, 1080.0 / 2400, accuracy: 1e-12)
        XCTAssertEqual(top.shares.map(\.slice).reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(top.weight, 600.0 / 2400, accuracy: 1e-12)
        XCTAssertGreaterThan(top.divergence, 0.08)
        XCTAssertLessThan(top.pValue, 1e-6)
        XCTAssertTrue(top.sentence.contains("South") && top.sentence.contains("80%"))
        XCTAssertEqual(top.filter.values, ["South"])
        // Channels have the overall distribution, so they are not reported; other regions differ only slightly.
        XCTAssertFalse(slices.contains { $0.dimension.name == "Channel" })
        XCTAssertFalse(slices.contains { $0.dimension.name == "Product" })
        for s in slices.dropFirst() { XCTAssertLessThan(s.divergence, top.divergence / 3) }
        XCTAssertEqual(DistributionDifference.jensenShannon([1, 0], [0, 1]), 1, accuracy: 1e-12)
        XCTAssertEqual(DistributionDifference.jensenShannon([0.3, 0.7], [0.3, 0.7]), 0, accuracy: 1e-12)
    }

    // MARK: Quick insights

    func testQuickInsights() throws {
        let cal = Calendar.utc
        let region = Self.region, date = FieldRef.column("Sales", "Date")
        let sales = FieldRef.column("Sales", "Amount", .sum), units = FieldRef.column("Sales", "Units", .sum), flat = FieldRef.column("Sales", "Flat", .sum)
        var rows: [[Value]] = []
        let regions = ["R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "Mega"]
        for m in 0..<36 {
            let d = cal.date(from: DateComponents(year: 2023 + m / 12, month: 1 + m % 12, day: 1))!
            for (i, r) in regions.enumerated() {
                let season = 1 + 0.3 * sin(2 * Double.pi * Double(m) / 12)
                var amount = (50 + Double(i) * 2 + Double(m)) * season
                if r == "Mega" { amount *= 20 }
                rows.append([.date(d), .string(r), .double(amount), .double(amount * 0.1 + Double(i)), .double(100 + Double(i % 2))])
            }
        }
        let t = DataTable(columnNames: ["Date", "Region", "Amount", "Units", "Flat"], rows: rows)
        let insights = QuickInsights.scan(dimensions: [region], measures: [sales, units, flat], dateField: date) { groupBy, measures in
            InMemoryQuery.aggregate(table: t, groupBy: groupBy.map(\.name), measures: measures.map { ($0.name, $0.aggregation) })
        }
        XCTAssertFalse(insights.isEmpty)
        XCTAssertEqual(insights.map(\.score), insights.map(\.score).sorted(by: >))
        let kinds = Set(insights.map(\.kind))
        XCTAssertTrue(kinds.contains(.majority)); XCTAssertTrue(kinds.contains(.categoryOutlier))
        XCTAssertTrue(kinds.contains(.correlation)); XCTAssertTrue(kinds.contains(.seasonality))
        XCTAssertTrue(kinds.contains(.lowVariance)); XCTAssertTrue(kinds.contains(.steadyShare))
        let majority = try XCTUnwrap(insights.first { $0.kind == .majority && $0.fields.contains { $0.name == "Amount" } })
        XCTAssertTrue(majority.sentence.contains("Mega"))
        XCTAssertEqual(majority.spec.type, .pie)
        XCTAssertEqual(majority.spec.fields(.legend).first?.name, "Region")
        let outlier = try XCTUnwrap(insights.first { $0.kind == .categoryOutlier })
        XCTAssertTrue(outlier.sentence.contains("Mega") && outlier.sentence.contains("higher"))
        let low = try XCTUnwrap(insights.first { $0.kind == .lowVariance })
        XCTAssertEqual(low.fields.last?.name, "Flat")
        let season = try XCTUnwrap(insights.first { $0.kind == .seasonality })
        XCTAssertTrue(season.sentence.contains("every 12 periods"))
        XCTAssertEqual(season.spec.type, .line)
        XCTAssertEqual(season.spec.fields(.category).first?.name, "Date")
        let corr = try XCTUnwrap(insights.first { $0.kind == .correlation })
        XCTAssertEqual(corr.spec.type, .scatter)
        XCTAssertFalse(insights.contains { $0.kind == .changePoint })

        // A level shift is reported as a change point, a steady climb as a trend.
        let stepRows: [[Value]] = (0..<30).map { i -> [Value] in
            let level = i < 18 ? 10 : 40
            return [.int(Int64(i)), .double(Double(level + i % 3)), .double(5 + 2 * Double(i) + Double(i % 2))]
        }
        let step = DataTable(columnNames: ["T", "V", "W"], rows: stepRows)
        let tf = FieldRef.column("X", "T"), v = FieldRef.column("X", "V", .sum), w = FieldRef.column("X", "W", .sum)
        let ti = QuickInsights.scan(dimensions: [], measures: [v, w], dateField: tf) { g, m in
            InMemoryQuery.aggregate(table: step, groupBy: g.map(\.name), measures: m.map { ($0.name, $0.aggregation) })
        }
        let cp = try XCTUnwrap(ti.first { $0.kind == .changePoint })
        XCTAssertEqual(cp.fields.last?.name, "V")
        XCTAssertTrue(cp.sentence.contains("up at 18"))
        let trend = try XCTUnwrap(ti.first { $0.kind == .trend })
        XCTAssertEqual(trend.fields.last?.name, "W")
        XCTAssertTrue(trend.sentence.contains("upward"))
        XCTAssertTrue(QuickInsights.scan(dimensions: [region], measures: [], query: { _, _ in DataTable() }).isEmpty)
    }
}
