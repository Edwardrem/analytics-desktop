import Foundation
import CoreGraphics
import FacetCore

/// Pure Model-view geometry: where table cards sit, what a point hits, how relationship lines are
/// routed and labelled, the star auto-arrange, and the viewport maths. No UI and no document
/// state, so all of it is unit-tested.
enum ModelDiagram {
    enum Metrics {
        static let cardWidth: CGFloat = 220
        static let minCardWidth: CGFloat = 160
        static let maxCardWidth: CGFloat = 480
        static let cardHeight: CGFloat = 260
        static let header: CGFloat = 34
        static let row: CGFloat = 22
        /// The "N more" row of a card too short for its fields.
        static let footer: CGFloat = 22
        static let bottomPad: CGFloat = 6
        /// Hit area of the collapse toggle, at the header's trailing edge.
        static let toggle: CGFloat = 28
        /// Hit area of the resize handle, in the bottom trailing corner.
        static let handle: CGFloat = 12
        static let padding: CGFloat = 40
        static let columnGap: CGFloat = 60
        static let rowGap: CGFloat = 80
        /// Clearance two cards need before a line runs straight between facing sides.
        static let clearance: CGFloat = 24
        static let laneSpacing: CGFloat = 16
        static let edgeTolerance: CGFloat = 6
        static let minZoom: CGFloat = 0.25
        static let maxZoom: CGFloat = 2
        static let unrelatedPerRow = 4
    }

    // MARK: Cards

    struct Field: Equatable, Identifiable {
        enum Kind: Equatable { case column, measure }
        var name: String
        var kind: Kind
        var glyph: String
        var isKey = false
        var isHidden = false
        var isCalculated = false
        var id: String { (kind == .column ? "c:" : "m:") + name }
        func ref(in table: String) -> ModelObjectRef {
            kind == .column ? .column(table: table, name: name) : .measure(table: table, name: name)
        }
    }

    struct CardLayout: Equatable, Identifiable {
        var table: String
        var frame: CGRect
        var collapsed: Bool
        /// The fields that fit, in order: columns, then measures.
        var fields: [Field]
        /// Fields the card is too short to show.
        var overflow: Int
        var glyph: String
        var isHidden: Bool
        var id: String { table }
    }

    /// Columns in model order, then measures.
    static func fields(of table: ModelTable) -> [Field] {
        table.columns.map { c in
            Field(name: c.name, kind: .column, glyph: ModelGlyph.symbol(for: c), isKey: c.isKey, isHidden: c.isHidden,
                  isCalculated: c.isCalculated || c.grouping != nil)
        } + table.measures.map { m in
            Field(name: m.name, kind: .measure, glyph: ModelGlyph.measure, isHidden: m.isHidden, isCalculated: true)
        }
    }

    /// Height of an expanded card that shows `count` fields without a "more" row.
    static func naturalHeight(fieldCount count: Int) -> CGFloat {
        Metrics.header + CGFloat(count) * Metrics.row + Metrics.bottomPad
    }

    /// How a stored card shows `count` fields: its size, how many fields fit and how many don't.
    /// The stored height is a ceiling; a card never grows past what its fields need.
    static func cardSize(fieldCount count: Int, card: ModelLayout.Card) -> (size: CGSize, visible: Int, overflow: Int) {
        let width = min(Metrics.maxCardWidth, max(Metrics.minCardWidth, CGFloat(card.width)))
        if card.collapsed { return (CGSize(width: width, height: Metrics.header), 0, 0) }
        let natural = naturalHeight(fieldCount: count)
        if natural <= CGFloat(card.height) { return (CGSize(width: width, height: natural), count, 0) }
        let room = CGFloat(card.height) - Metrics.header - Metrics.footer - Metrics.bottomPad
        let visible = min(count, max(1, Int(room / Metrics.row)))
        let height = Metrics.header + CGFloat(visible) * Metrics.row + Metrics.footer + Metrics.bottomPad
        return (CGSize(width: width, height: height), visible, count - visible)
    }

    static func cardLayout(_ table: ModelTable, card: ModelLayout.Card) -> CardLayout {
        let all = fields(of: table)
        let sized = cardSize(fieldCount: all.count, card: card)
        return CardLayout(table: table.name,
                          frame: CGRect(origin: CGPoint(x: card.x, y: card.y), size: sized.size),
                          collapsed: card.collapsed, fields: Array(all.prefix(sized.visible)), overflow: sized.overflow,
                          glyph: ModelGlyph.symbol(for: table), isHidden: table.isHidden)
    }

    static func fieldRect(_ card: CardLayout, index: Int) -> CGRect {
        CGRect(x: card.frame.minX, y: card.frame.minY + Metrics.header + CGFloat(index) * Metrics.row,
               width: card.frame.width, height: Metrics.row)
    }

    static func toggleRect(_ card: CardLayout) -> CGRect {
        CGRect(x: card.frame.maxX - Metrics.toggle, y: card.frame.minY, width: Metrics.toggle, height: Metrics.header)
    }

    static func handleRect(_ card: CardLayout) -> CGRect {
        CGRect(x: card.frame.maxX - Metrics.handle, y: card.frame.maxY - Metrics.handle, width: Metrics.handle, height: Metrics.handle)
    }

    static func moreRect(_ card: CardLayout) -> CGRect? {
        guard card.overflow > 0, !card.collapsed else { return nil }
        return CGRect(x: card.frame.minX, y: card.frame.minY + Metrics.header + CGFloat(card.fields.count) * Metrics.row,
                      width: card.frame.width, height: Metrics.footer)
    }

    // MARK: Placement

    /// The stored card for a table, matched the way the model matches names.
    static func storedCard(_ layout: ModelLayout, _ table: String) -> ModelLayout.Card? {
        if let card = layout.cards[table] { return card }
        return layout.cards.first { ModelDAX.same($0.key, table) }?.value
    }

    /// The tables a layout shows, with their cards. "All tables" shows every table: with no stored
    /// positions the model is auto-arranged; tables added since are lined up under the rest.
    /// Other layouts show exactly the tables they hold a card for.
    static func placements(model: SemanticModel, layout: ModelLayout) -> [(table: ModelTable, card: ModelLayout.Card)] {
        guard layout.showsAllTables else {
            return model.tables.compactMap { t in storedCard(layout, t.name).map { (t, $0) } }
        }
        var placed: [(table: ModelTable, card: ModelLayout.Card)] = []
        var missing: [ModelTable] = []
        for t in model.tables {
            if let card = storedCard(layout, t.name) { placed.append((t, card)) } else { missing.append(t) }
        }
        if missing.isEmpty { return placed }
        func size(_ t: ModelTable) -> CGSize { cardSize(fieldCount: t.columns.count + t.measures.count, card: ModelLayout.Card(x: 0, y: 0)).size }
        var origins: [String: CGPoint]
        if placed.isEmpty {
            origins = autoArrange(tables: missing.map { ($0.name, size($0)) }, relationships: model.relationships)
        } else {
            let bottom = placed.map { p in CGFloat(p.card.y) + cardSize(fieldCount: p.table.columns.count + p.table.measures.count, card: p.card).size.height }.max() ?? 0
            let left = placed.map { CGFloat($0.card.x) }.min() ?? Metrics.padding
            origins = grid(missing.map { ($0.name, size($0)) }, origin: CGPoint(x: left, y: bottom + Metrics.rowGap))
        }
        var byName: [String: ModelLayout.Card] = [:]
        for t in missing {
            let o = origins[t.name] ?? CGPoint(x: Metrics.padding, y: Metrics.padding)
            byName[t.name] = ModelLayout.Card(x: Double(o.x), y: Double(o.y))
        }
        // Model order, so the scene is stable as cards are stored one by one.
        return model.tables.compactMap { t in
            if let p = placed.first(where: { $0.table.id == t.id }) { return p }
            return byName[t.name].map { (t, $0) }
        }
    }

    /// Lines cards up left to right, wrapping after `Metrics.unrelatedPerRow`.
    static func grid(_ tables: [(name: String, size: CGSize)], origin: CGPoint) -> [String: CGPoint] {
        var out: [String: CGPoint] = [:]
        var x = origin.x, y = origin.y, tallest: CGFloat = 0
        for (i, t) in tables.enumerated() {
            if i > 0, i % Metrics.unrelatedPerRow == 0 {
                x = origin.x
                y += tallest + Metrics.rowGap
                tallest = 0
            }
            out[t.name] = CGPoint(x: x, y: y)
            x += t.size.width + Metrics.columnGap
            tallest = max(tallest, t.size.height)
        }
        return out
    }

    // MARK: Auto-arrange

    /// Which side of a relationship is the "many" side, for telling fact tables from dimensions.
    /// One-to-one and many-to-many have no such side.
    static func manySide(_ r: Relationship) -> String? {
        switch r.cardinality {
        case .manyToOne: return r.fromTable
        case .oneToMany: return r.toTable
        case .oneToOne, .manyToMany: return nil
        }
    }
    static func oneSide(_ r: Relationship) -> String? {
        switch r.cardinality {
        case .manyToOne: return r.toTable
        case .oneToMany: return r.fromTable
        case .oneToOne, .manyToMany: return nil
        }
    }

    /// Star layout. Fact tables (on the many side of a relationship and never on the one side)
    /// sit in the middle row; the dimensions related to them alternate above and below; tables
    /// further out (snowflake) go one row beyond the table they hang off, on its side; tables with
    /// no relationships are lined up underneath. Rows are centred on each other. Returns each
    /// table's top-left corner, with the whole arrangement starting at `Metrics.padding`.
    static func autoArrange(tables: [(name: String, size: CGSize)], relationships: [Relationship]) -> [String: CGPoint] {
        guard !tables.isEmpty else { return [:] }
        let key: (String) -> String = { $0.lowercased() }
        let known = Set(tables.map { key($0.name) })
        let links = relationships.filter { known.contains(key($0.fromTable)) && known.contains(key($0.toTable)) && key($0.fromTable) != key($0.toTable) }
        var neighbours: [String: [String]] = [:]
        var many = Set<String>(), one = Set<String>()
        for r in links {
            neighbours[key(r.fromTable), default: []].append(key(r.toTable))
            neighbours[key(r.toTable), default: []].append(key(r.fromTable))
            if let m = manySide(r) { many.insert(key(m)) }
            if let o = oneSide(r) { one.insert(key(o)) }
        }
        let related = tables.filter { neighbours[key($0.name)] != nil }
        var centre = related.filter { many.contains(key($0.name)) && !one.contains(key($0.name)) }.map { key($0.name) }
        if centre.isEmpty {
            // No clear fact table: the table with the most relationships, the earliest on a tie.
            let most = related.map { neighbours[key($0.name)]?.count ?? 0 }.max() ?? 0
            if let busiest = related.first(where: { (neighbours[key($0.name)]?.count ?? 0) == most }) { centre = [key(busiest.name)] }
        }

        // Signed row per table: 0 for the centre, ±1 for its dimensions, ±2 beyond them…
        var rowOf: [String: Int] = [:]
        for c in centre { rowOf[c] = 0 }
        var frontier = centre
        var level = 0
        var alternate = 0
        while !frontier.isEmpty {
            level += 1
            var next: [String] = []
            // Visit in table order so the result does not depend on relationship order.
            for t in tables.map({ key($0.name) }) where rowOf[t] == nil {
                guard let parent = frontier.first(where: { neighbours[$0]?.contains(t) == true }) else { continue }
                if level == 1 {
                    rowOf[t] = alternate % 2 == 0 ? -1 : 1
                    alternate += 1
                } else {
                    rowOf[t] = (rowOf[parent] ?? 1) < 0 ? -level : level
                }
                next.append(t)
            }
            frontier = next
        }

        // A second cluster the centre can't reach is treated like unrelated tables.
        let rows = Dictionary(grouping: tables.filter { rowOf[key($0.name)] != nil }) { rowOf[key($0.name)] ?? 0 }
        var out: [String: CGPoint] = [:]
        var y: CGFloat = 0
        var minX: CGFloat = 0
        for index in rows.keys.sorted() {
            let row = rows[index] ?? []
            let width = row.reduce(0) { $0 + $1.size.width } + CGFloat(max(0, row.count - 1)) * Metrics.columnGap
            var x = -width / 2
            minX = min(minX, x)
            for t in row {
                out[t.name] = CGPoint(x: x, y: y)
                x += t.size.width + Metrics.columnGap
            }
            y += (row.map(\.size.height).max() ?? 0) + Metrics.rowGap
        }
        let loose = tables.filter { rowOf[key($0.name)] == nil }
        if !loose.isEmpty {
            let perRow = min(loose.count, Metrics.unrelatedPerRow)
            let width = loose.prefix(perRow).reduce(0) { $0 + $1.size.width } + CGFloat(perRow - 1) * Metrics.columnGap
            let origin = CGPoint(x: out.isEmpty ? 0 : -width / 2, y: y)
            minX = min(minX, origin.x)
            for (name, p) in grid(loose, origin: origin) { out[name] = p }
        }
        let dx = Metrics.padding - minX, dy = Metrics.padding
        return out.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    // MARK: Relationship lines

    enum Side: Equatable { case left, right, top, bottom }
    enum FilterDirection: Equatable { case towardFrom, towardTo, both }

    struct Edge: Equatable, Identifiable {
        var id: UUID
        var fromTable: String
        var toTable: String
        /// The line, from the `from` table's card to the `to` table's card.
        var points: [CGPoint]
        var fromSide: Side
        var toSide: Side
        /// "1" or "*" at each end.
        var fromLabel: String
        var toLabel: String
        var fromLabelPoint: CGPoint
        var toLabelPoint: CGPoint
        var direction: FilterDirection
        /// Inactive relationships draw dashed.
        var isActive: Bool
        /// Where the cross-filter arrow sits, and the unit direction of the line there (from → to).
        var arrowPoint: CGPoint
        var arrowDirection: CGVector
    }

    /// "1" or "*" for each end, the same marks the relationship editor shows.
    static func endLabels(_ cardinality: Cardinality) -> (from: String, to: String) {
        RelationshipEditLogic.endMarks(cardinality)
    }

    /// Which way filters flow. With a single direction the one side filters the many side; for
    /// one-to-one and many-to-many the `to` table filters the `from` table.
    static func filterDirection(_ r: Relationship) -> FilterDirection {
        if r.crossFilter == .both { return .both }
        return r.cardinality == .oneToMany ? .towardTo : .towardFrom
    }

    /// Routes a line between two cards. Facing sides when the cards are clear of each other
    /// horizontally, top and bottom when stacked, and a loop round the right when they overlap.
    /// `fromY`/`toY` are the related columns' rows (nil: the card's middle); `lane` spreads
    /// parallel lines between the same two stacked cards.
    static func route(from: CGRect, fromY: CGFloat?, to: CGRect, toY: CGFloat?, lane: CGFloat = 0) -> (points: [CGPoint], fromSide: Side, toSide: Side) {
        let fy = fromY ?? from.midY, ty = toY ?? to.midY
        if from.maxX + Metrics.clearance <= to.minX {
            let mid = (from.maxX + to.minX) / 2
            return ([CGPoint(x: from.maxX, y: fy), CGPoint(x: mid, y: fy), CGPoint(x: mid, y: ty), CGPoint(x: to.minX, y: ty)], .right, .left)
        }
        if to.maxX + Metrics.clearance <= from.minX {
            let mid = (to.maxX + from.minX) / 2
            return ([CGPoint(x: from.minX, y: fy), CGPoint(x: mid, y: fy), CGPoint(x: mid, y: ty), CGPoint(x: to.maxX, y: ty)], .left, .right)
        }
        let offset = lane * Metrics.laneSpacing
        if from.maxY + Metrics.clearance <= to.minY {
            let mid = (from.maxY + to.minY) / 2
            return ([CGPoint(x: from.midX + offset, y: from.maxY), CGPoint(x: from.midX + offset, y: mid),
                     CGPoint(x: to.midX + offset, y: mid), CGPoint(x: to.midX + offset, y: to.minY)], .bottom, .top)
        }
        if to.maxY + Metrics.clearance <= from.minY {
            let mid = (to.maxY + from.minY) / 2
            return ([CGPoint(x: from.midX + offset, y: from.minY), CGPoint(x: from.midX + offset, y: mid),
                     CGPoint(x: to.midX + offset, y: mid), CGPoint(x: to.midX + offset, y: to.maxY)], .top, .bottom)
        }
        let x = max(from.maxX, to.maxX) + Metrics.clearance + abs(offset)
        return ([CGPoint(x: from.maxX, y: fy), CGPoint(x: x, y: fy), CGPoint(x: x, y: ty), CGPoint(x: to.maxX, y: ty)], .right, .right)
    }

    /// Where the "1" / "*" sits for a line leaving a card on `side` at `anchor`: a little way out
    /// along the line and to one side of it.
    static func labelPoint(anchor: CGPoint, side: Side) -> CGPoint {
        switch side {
        case .right: return CGPoint(x: anchor.x + 12, y: anchor.y - 9)
        case .left: return CGPoint(x: anchor.x - 12, y: anchor.y - 9)
        case .top: return CGPoint(x: anchor.x + 10, y: anchor.y - 12)
        case .bottom: return CGPoint(x: anchor.x + 10, y: anchor.y + 12)
        }
    }

    /// The point half way along a polyline and the unit direction of the segment it is on.
    static func midpoint(of points: [CGPoint]) -> (point: CGPoint, direction: CGVector) {
        guard let first = points.first else { return (.zero, CGVector(dx: 1, dy: 0)) }
        var lengths: [CGFloat] = []
        for i in 1..<max(1, points.count) { lengths.append(hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return (first, CGVector(dx: 1, dy: 0)) }
        var remaining = total / 2
        for (i, length) in lengths.enumerated() where length > 0 {
            if remaining <= length {
                let a = points[i], b = points[i + 1]
                let t = remaining / length
                return (CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                        CGVector(dx: (b.x - a.x) / length, dy: (b.y - a.y) / length))
            }
            remaining -= length
        }
        return (points[points.count - 1], CGVector(dx: 1, dy: 0))
    }

    /// The vertical centre of a column's row in a card, when that row is showing.
    static func anchorY(_ card: CardLayout, column: String) -> CGFloat? {
        guard !card.collapsed,
              let i = card.fields.firstIndex(where: { $0.kind == .column && ModelDAX.same($0.name, column) }) else { return nil }
        return fieldRect(card, index: i).midY
    }

    static func edges(model: SemanticModel, cards: [CardLayout]) -> [Edge] {
        func card(_ name: String) -> CardLayout? { cards.first { ModelDAX.same($0.table, name) } }
        func pair(_ r: Relationship) -> String { [r.fromTable.lowercased(), r.toTable.lowercased()].sorted().joined(separator: "\u{1F}") }
        var perPair: [String: Int] = [:]
        let shown = model.relationships.filter { card($0.fromTable) != nil && card($0.toTable) != nil && !ModelDAX.same($0.fromTable, $0.toTable) }
        for r in shown { perPair[pair(r), default: 0] += 1 }
        var seen: [String: Int] = [:]
        return shown.compactMap { r in
            guard let a = card(r.fromTable), let b = card(r.toTable) else { return nil }
            let index = seen[pair(r), default: 0]
            seen[pair(r)] = index + 1
            let lane = CGFloat(index) - CGFloat((perPair[pair(r)] ?? 1) - 1) / 2
            let routed = route(from: a.frame, fromY: anchorY(a, column: r.fromColumn), to: b.frame, toY: anchorY(b, column: r.toColumn), lane: lane)
            guard let first = routed.points.first, let last = routed.points.last else { return nil }
            let labels = endLabels(r.cardinality)
            let mid = midpoint(of: routed.points)
            return Edge(id: r.id, fromTable: a.table, toTable: b.table, points: routed.points,
                        fromSide: routed.fromSide, toSide: routed.toSide,
                        fromLabel: labels.from, toLabel: labels.to,
                        fromLabelPoint: labelPoint(anchor: first, side: routed.fromSide),
                        toLabelPoint: labelPoint(anchor: last, side: routed.toSide),
                        direction: filterDirection(r), isActive: r.isActive,
                        arrowPoint: mid.point, arrowDirection: mid.direction)
        }
    }

    // MARK: Scene

    struct Scene: Equatable {
        var cards: [CardLayout] = []
        var edges: [Edge] = []
        /// The rectangle holding every card; `.zero` for an empty diagram.
        var bounds: CGRect {
            guard let first = cards.first else { return .zero }
            return cards.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        }
        func card(_ table: String) -> CardLayout? { cards.first { ModelDAX.same($0.table, table) } }
    }

    /// Everything a layout tab draws. `overrides` replaces stored cards while one is being dragged
    /// or resized; `front` names the table drawn (and hit) on top.
    static func scene(model: SemanticModel, layout: ModelLayout, overrides: [String: ModelLayout.Card] = [:], front: String? = nil) -> Scene {
        var cards = placements(model: model, layout: layout).map { p in
            cardLayout(p.table, card: overrides.first { ModelDAX.same($0.key, p.table.name) }?.value ?? p.card)
        }
        if let front, let i = cards.firstIndex(where: { ModelDAX.same($0.table, front) }) {
            cards.append(cards.remove(at: i))
        }
        return Scene(cards: cards, edges: edges(model: model, cards: cards))
    }

    // MARK: Hit-testing

    enum Hit: Equatable {
        case toggle(String)
        case resize(String)
        case more(String)
        case header(String)
        case field(table: String, name: String, kind: Field.Kind)
        /// Inside a card, on nothing in particular.
        case card(String)
        case edge(UUID)
        case canvas

        var table: String? {
            switch self {
            case .toggle(let t), .resize(let t), .more(let t), .header(let t), .card(let t), .field(let t, _, _): return t
            case .edge, .canvas: return nil
            }
        }
    }

    /// What a point in canvas coordinates is on. Cards are tested top-most first (the last card
    /// in the scene is drawn last), then lines within `tolerance`.
    static func hit(_ p: CGPoint, in scene: Scene, tolerance: CGFloat = Metrics.edgeTolerance) -> Hit {
        for card in scene.cards.reversed() where card.frame.contains(p) {
            if !card.collapsed, handleRect(card).contains(p) { return .resize(card.table) }
            if p.y < card.frame.minY + Metrics.header {
                return toggleRect(card).contains(p) ? .toggle(card.table) : .header(card.table)
            }
            let index = Int((p.y - card.frame.minY - Metrics.header) / Metrics.row)
            if let field = card.fields[safe: index] { return .field(table: card.table, name: field.name, kind: field.kind) }
            if moreRect(card)?.contains(p) == true { return .more(card.table) }
            return .card(card.table)
        }
        var best: (id: UUID, distance: CGFloat)?
        for edge in scene.edges {
            let d = distance(from: p, toPolyline: edge.points)
            if d <= tolerance, d < (best?.distance ?? .infinity) { best = (edge.id, d) }
        }
        return best.map { .edge($0.id) } ?? .canvas
    }

    static func distance(from p: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard var previous = points.first else { return .infinity }
        var best = hypot(p.x - previous.x, p.y - previous.y)
        for q in points.dropFirst() {
            let dx = q.x - previous.x, dy = q.y - previous.y
            let length2 = dx * dx + dy * dy
            let t = length2 == 0 ? 0 : max(0, min(1, ((p.x - previous.x) * dx + (p.y - previous.y) * dy) / length2))
            best = min(best, hypot(p.x - (previous.x + t * dx), p.y - (previous.y + t * dy)))
            previous = q
        }
        return best
    }

    // MARK: Relationship validation

    /// Why dropping one column on another can't create a relationship, or nil when it can: the
    /// same table, columns that are already related, or data types that don't match.
    static func dropProblem(model: SemanticModel, fromTable: String, fromColumn: String, toTable: String, toColumn: String) -> String? {
        RelationshipLogic.problem(Relationship(fromTable: fromTable, fromColumn: fromColumn, toTable: toTable, toColumn: toColumn), model: model)
    }

    // MARK: Card edits

    static func moved(_ card: ModelLayout.Card, by delta: CGSize) -> ModelLayout.Card {
        var c = card
        c.x += Double(delta.width)
        c.y += Double(delta.height)
        return c
    }

    /// Resizes a card by a drag of its corner, within the width limits and never shorter than
    /// one field row plus the "more" row.
    static func resized(_ card: ModelLayout.Card, from size: CGSize, by delta: CGSize) -> ModelLayout.Card {
        var c = card
        c.width = Double(min(Metrics.maxCardWidth, max(Metrics.minCardWidth, size.width + delta.width)))
        let least = Metrics.header + Metrics.row + Metrics.footer + Metrics.bottomPad
        c.height = Double(max(least, size.height + delta.height))
        return c
    }

    // MARK: Viewport

    struct Viewport: Equatable {
        var zoom: CGFloat = 1
        var offset: CGSize = .zero
        func toCanvas(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.width) / zoom, y: (p.y - offset.height) / zoom) }
        func toScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom + offset.width, y: p.y * zoom + offset.height) }
    }

    static func clampZoom(_ zoom: CGFloat) -> CGFloat { min(Metrics.maxZoom, max(Metrics.minZoom, zoom)) }

    /// Zooms by `factor`, keeping the canvas point under `anchor` (a screen point) where it is.
    static func zoomed(_ v: Viewport, by factor: CGFloat, around anchor: CGPoint) -> Viewport {
        let zoom = clampZoom(v.zoom * factor)
        let c = v.toCanvas(anchor)
        return Viewport(zoom: zoom, offset: CGSize(width: anchor.x - c.x * zoom, height: anchor.y - c.y * zoom))
    }

    /// The viewport that shows all of `bounds`, centred, with `Metrics.padding` around it. Never
    /// zooms in past 100%.
    static func fit(_ bounds: CGRect, in size: CGSize) -> Viewport {
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else { return Viewport() }
        let room = CGSize(width: max(1, size.width - 2 * Metrics.padding), height: max(1, size.height - 2 * Metrics.padding))
        let zoom = max(Metrics.minZoom, min(1, min(room.width / bounds.width, room.height / bounds.height)))
        return Viewport(zoom: zoom,
                        offset: CGSize(width: (size.width - bounds.width * zoom) / 2 - bounds.minX * zoom,
                                       height: (size.height - bounds.height * zoom) / 2 - bounds.minY * zoom))
    }
}
