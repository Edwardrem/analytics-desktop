import Foundation
import CoreGraphics
import FacetCore

/// The checks and decisions behind the assistant's report-authoring tools, kept free of the UI so they can be
/// tested: which model field a reference names, which well each field goes in, and where a visual can sit
/// without covering another. Nothing here touches the document; the tools apply the result through the store.
@MainActor
enum AssistantAuthoring {
    /// One field a tool call asks for: a reference such as `'Sales'[Amount]`, `Sales[Amount]` or `[Total Sales]`,
    /// optionally the well and the aggregation to use.
    struct FieldRequest: Equatable {
        var reference: String
        var well: String?
        var aggregation: String?
    }

    /// A visual a tool call asks for, before it is checked.
    struct VisualRequest: Equatable {
        var type: String
        var fields: [FieldRequest] = []
        var title: String?
        /// Text for a text box.
        var text: String?
    }

    enum Problem: LocalizedError, Equatable {
        case unknownVisualType(String)
        case badReference(String)
        case unknownTable(String)
        case unknownField(String, suggestions: [String])
        case ambiguousField(String, tables: [String])
        case unknownWell(String, type: String, wells: [String])
        case measureInGroupingWell(String, well: String)
        case unknownAggregation(String)
        case noFields(String)
        case noRoom
        case tooManyVisuals(Int)

        var errorDescription: String? {
            switch self {
            case .unknownVisualType(let t):
                return "Unknown visual type \"\(t)\". Use one of: \(AssistantAuthoring.typeNames.joined(separator: ", "))."
            case .badReference(let r): return "\"\(r)\" is not a field reference. Write 'Table'[Column] or [Measure]."
            case .unknownTable(let t): return "The model has no table named \"\(t)\"."
            case .unknownField(let r, let s):
                return "The model has no column or measure \(r)." + (s.isEmpty ? "" : " Did you mean \(s.joined(separator: " or "))?")
            case .ambiguousField(let r, let tables):
                return "\(r) is a column in more than one table (\(tables.joined(separator: ", "))). Name the table: 'Table'[Column]."
            case .unknownWell(let w, let type, let wells):
                return "A \(type) has no \"\(w)\" well. Its wells are: \(wells.joined(separator: ", "))."
            case .measureInGroupingWell(let m, let well):
                return "The measure \(m) can't go in \(well), which groups by column values. Put a column there."
            case .unknownAggregation(let a):
                return "Unknown aggregation \"\(a)\". Use sum, average, min, max, count, distinctCount or median."
            case .noFields(let type): return "Give the fields the \(type) should show."
            case .noRoom: return "There is no free space on the page for this visual. Make room, or create a new page for it."
            case .tooManyVisuals(let n): return "A page can take at most \(n) visuals from one request."
            }
        }
    }

    static let maxVisualsPerPage = 12

    // MARK: Visual types

    /// Friendly names the tools accept, besides any visual type's raw value or display name.
    static let typeAliases: [String: VisualType] = [
        "column": .clusteredColumn, "bar": .clusteredBar, "stackedcolumn": .stackedColumn, "stackedbar": .stackedBar,
        "line": .line, "area": .area, "pie": .pie, "donut": .donut, "card": .card, "table": .table, "matrix": .matrix,
        "scatter": .scatter, "treemap": .treemap, "slicer": .slicer, "gauge": .gauge, "kpi": .kpi,
        "funnel": .funnel, "waterfall": .waterfall, "textbox": .textBox, "text": .textBox, "combo": .lineClusteredColumn,
    ]
    nonisolated static let typeNames = ["column", "bar", "stackedColumn", "stackedBar", "line", "area", "pie", "donut", "card", "table",
                            "matrix", "scatter", "treemap", "slicer", "gauge", "kpi", "funnel", "waterfall", "combo", "textBox"]

    static func visualType(_ name: String) -> VisualType? {
        let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if let t = typeAliases[key] { return t }
        return VisualType.allCases.first { t in
            t.rawValue.lowercased() == key || t.displayName.lowercased().filter { $0.isLetter || $0.isNumber } == key
        }
    }

    // MARK: Fields

    /// Splits a reference into its table (when written) and name. Accepts `'Table'[Name]`, `Table[Name]`, `[Name]`.
    static func parseReference(_ text: String) -> (table: String?, name: String)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasSuffix("]"), let open = s.lastIndex(of: "[") else { return nil }
        let name = String(s[s.index(after: open)..<s.index(before: s.endIndex)]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var table = String(s[..<open]).trimmingCharacters(in: .whitespaces)
        if table.hasPrefix("'"), table.hasSuffix("'"), table.count >= 2 {
            table = String(table.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return (table.isEmpty ? nil : table, name)
    }

    /// The model field a reference names: a measure, or a column. A bare `[Name]` may name a measure anywhere,
    /// or a column when exactly one table has it.
    static func resolve(_ reference: String, in model: SemanticModel) throws -> FieldRef {
        guard let (tableName, name) = parseReference(reference) else { throw Problem.badReference(reference) }
        if let tableName {
            guard let table = model.table(tableName) else { throw Problem.unknownTable(tableName) }
            if let m = table.measure(name) { return .measure(table.name, m.name) }
            if let c = table.column(name) { return .column(table.name, c.name) }
            // A measure is often written with any table in front of it.
            if let hit = model.measure(name) { return .measure(hit.table.name, hit.measure.name) }
            throw Problem.unknownField(reference, suggestions: suggestions(for: name, in: model))
        }
        if let hit = model.measure(name) { return .measure(hit.table.name, hit.measure.name) }
        let owners = model.tables.filter { $0.column(name) != nil }
        if owners.count == 1, let t = owners.first, let c = t.column(name) { return .column(t.name, c.name) }
        if owners.count > 1 { throw Problem.ambiguousField(reference, tables: owners.map(\.name)) }
        throw Problem.unknownField(reference, suggestions: suggestions(for: name, in: model))
    }

    /// Up to three fields whose names contain the requested one, or that it contains.
    static func suggestions(for name: String, in model: SemanticModel) -> [String] {
        let key = name.lowercased()
        guard key.count >= 3 else { return [] }
        var out: [String] = []
        for t in model.tables where !t.isHidden {
            for m in t.measures where !m.isHidden && (m.name.lowercased().contains(key) || key.contains(m.name.lowercased())) {
                out.append("[\(m.name)]")
            }
            for c in t.columns where !c.isHidden && (c.name.lowercased().contains(key) || key.contains(c.name.lowercased())) {
                out.append("'\(t.name)'[\(c.name)]")
            }
        }
        return Array(out.prefix(3))
    }

    static func aggregation(_ name: String) throws -> Aggregation {
        let key = name.lowercased().filter(\.isLetter)
        let aliases: [String: Aggregation] = ["avg": .average, "mean": .average, "countdistinct": .distinctCount, "distinct": .distinctCount,
                                              "minimum": .min, "maximum": .max, "total": .sum, "none": .none, "dontsummarize": .none]
        if let a = aliases[key] { return a }
        if let a = Aggregation.allCases.first(where: { $0.rawValue.lowercased() == key }) { return a }
        throw Problem.unknownAggregation(name)
    }

    static func well(_ name: String, of type: VisualType) throws -> Well {
        let key = name.lowercased().filter(\.isLetter)
        let aliases: [String: Well] = ["axis": .category, "xaxis": .x, "yaxis": .y, "value": .values, "series": .legend,
                                       "row": .rows, "column": .columns, "fields": .field, "tooltip": .tooltips]
        let wells = type.wells
        let found = aliases[key].flatMap { wells.contains($0) ? $0 : nil }
            ?? wells.first { $0.rawValue.lowercased() == key || $0.displayName.lowercased().filter(\.isLetter) == key }
        guard let w = found else { throw Problem.unknownWell(name, type: type.displayName, wells: wells.map(\.rawValue)) }
        return w
    }

    /// Puts each field in a well of `type`: the named well when given; otherwise numbers (measures, aggregated or
    /// summarized numeric columns) fill the value wells and other columns the grouping wells, first empty one first.
    /// - Parameter defaultAggregation: the aggregation a column gets when it lands in a value well.
    static func bind(_ requests: [FieldRequest], to type: VisualType, model: SemanticModel,
                     defaultAggregation: (FieldRef) -> Aggregation) throws -> [(Well, FieldRef)] {
        let wells = type.wells
        let valueWells = wells.filter { !$0.isGrouping && $0 != .tooltips }
        // A card shows one value per field: everything goes in Fields unless a well is named.
        let isCard = [.card, .cardLegacy, .multiRowCard].contains(type)
        let groupWells = isCard ? [] : wells.filter(\.isGrouping)
        var placed: [(Well, FieldRef)] = []
        func isEmpty(_ w: Well) -> Bool { !placed.contains { $0.0 == w } }
        for r in requests {
            var field = try resolve(r.reference, in: model)
            let explicitAggregation = try r.aggregation.map(aggregation)
            let column = field.kind == .column ? model.table(field.table)?.column(field.name) : nil
            let numeric = field.kind == .measure || (explicitAggregation.map { $0 != .none } ?? false)
                || (column.map { $0.dataType.isNumeric && $0.summarizeBy != .none } ?? false)
            let target: Well
            if let named = r.well {
                target = try well(named, of: type)
            } else if !numeric, let g = groupWells.first(where: isEmpty) ?? groupWells.first {
                target = g
            } else {
                guard let w = valueWells.first(where: isEmpty) ?? valueWells.first(where: { $0 == .values }) ?? valueWells.first ?? wells.first
                else { throw Problem.unknownWell("values", type: type.displayName, wells: []) }
                target = w
            }
            if field.kind == .measure, target.isGrouping { throw Problem.measureInGroupingWell(r.reference, well: target.displayName) }
            if field.kind == .column {
                if target.isGrouping { field.aggregation = .none }
                else if let a = explicitAggregation { field.aggregation = a }
                else if type == .table || type == .multiRowCard { field.aggregation = numeric ? defaultAggregation(field) : .none }
                else { field.aggregation = defaultAggregation(field) }
                // A value well needs one number per group; a text column there is counted.
                if !target.isGrouping, field.aggregation == .none, type != .table, type != .multiRowCard { field.aggregation = .count }
            }
            placed.append((target, field))
        }
        return placed
    }

    /// A checked visual, ready to add: type, fields by well, title, text.
    static func build(_ request: VisualRequest, model: SemanticModel, frame: Frame, name: String,
                      defaultAggregation: (FieldRef) -> Aggregation) throws -> VisualSpec {
        guard let type = visualType(request.type) else { throw Problem.unknownVisualType(request.type) }
        var spec = VisualSpec(type: type, frame: frame, name: name)
        if type == .textBox {
            spec.content = request.text ?? request.title ?? ""
            return spec
        }
        let placed = try bind(request.fields, to: type, model: model, defaultAggregation: defaultAggregation)
        if placed.isEmpty, !type.wells.isEmpty { throw Problem.noFields(type.displayName) }
        for w in type.wells {
            let fields = placed.filter { $0.0 == w }.map(\.1)
            if !fields.isEmpty { spec.setFields(w, fields) }
        }
        if let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            spec.name = title
            spec.setFmt("title", "text", .string(title))
        }
        return spec
    }

    /// "Axis = Region; Values = Sum of Amount".
    static func summary(_ spec: VisualSpec) -> String {
        let parts = spec.type.wells.compactMap { w -> String? in
            let f = spec.fields(w)
            return f.isEmpty ? nil : "\(w.displayName) = \(f.map(\.caption).joined(separator: ", "))"
        }
        return parts.isEmpty ? "no fields" : parts.joined(separator: "; ")
    }

    // MARK: Layout

    static let margin = 24.0, gap = 16.0

    /// The default size of a visual of this type, as Insert gives it.
    static func size(for type: VisualType) -> CGSize {
        let s = DocumentStore.defaultSize(for: type)
        return CGSize(width: s.w, height: s.h)
    }

    /// The first spot, scanning rows from the top left on an 8-point grid, where a `size` rectangle stays inside the
    /// page margins and keeps `gap` clear of every occupied rectangle; nil when there is none.
    static func freeSpot(for size: CGSize, page: CGSize, occupied: [CGRect]) -> CGPoint? {
        let step = 8.0
        var y = margin
        while y + size.height <= page.height - margin + 0.5 {
            var x = margin
            while x + size.width <= page.width - margin + 0.5 {
                let r = CGRect(x: x, y: y, width: size.width, height: size.height)
                if !occupied.contains(where: { $0.insetBy(dx: -gap + 0.5, dy: -gap + 0.5).intersects(r) }) { return CGPoint(x: x, y: y) }
                x += step
            }
            y += step
        }
        return nil
    }

    /// Where a new visual goes on a page that already has visuals: the default size if it fits anywhere, else
    /// three quarters, then half of it. Throws `noRoom` rather than overlap another visual.
    static func place(_ type: VisualType, page: CGSize, occupied: [CGRect]) throws -> Frame {
        let base = size(for: type)
        for scale in [1.0, 0.75, 0.5] {
            let s = CGSize(width: (base.width * scale).rounded(), height: (base.height * scale).rounded())
            if let p = freeSpot(for: s, page: page, occupied: occupied) {
                return Frame(x: p.x, y: p.y, width: s.width, height: s.height)
            }
        }
        throw Problem.noRoom
    }

    /// A tidy layout for a new page: cards, KPIs, slicers and text boxes in a band across the top, then the other
    /// visuals in a grid (one column for one visual, two for two to four, three beyond) filling the rest of the page.
    static func pageLayout(_ types: [VisualType], page: CGSize) -> [Frame] {
        func isSmall(_ t: VisualType) -> Bool { [.card, .cardLegacy, .kpi, .textBox, .slicer, .listSlicer, .buttonSlicer, .inputSlicer, .multiRowCard].contains(t) }
        let width = page.width - 2 * margin
        var frames = [Frame?](repeating: nil, count: types.count)
        // Top band: small visuals side by side, sharing the width equally when they would not fit at their size.
        let small = types.indices.filter { isSmall(types[$0]) }
        var top = margin
        if !small.isEmpty {
            let natural = small.map { size(for: types[$0]) }
            let bandHeight = min(natural.map(\.height).max() ?? 130, 160)
            let totalWidth = natural.reduce(0) { $0 + $1.width } + gap * Double(small.count - 1)
            let share = (width - gap * Double(small.count - 1)) / Double(small.count)
            var x = margin
            for (k, i) in small.enumerated() {
                let w = totalWidth <= width ? natural[k].width : share
                frames[i] = Frame(x: x.rounded(), y: top, width: w.rounded(down: true), height: bandHeight)
                x += w + gap
            }
            top += bandHeight + gap
        }
        let large = types.indices.filter { !isSmall(types[$0]) }
        if !large.isEmpty {
            let columns = large.count == 1 ? 1 : (large.count <= 4 ? 2 : 3)
            let rows = (large.count + columns - 1) / columns
            let cellWidth = (width - gap * Double(columns - 1)) / Double(columns)
            let available = page.height - margin - top
            let cellHeight = max(160, (available - gap * Double(rows - 1)) / Double(rows))
            for (k, i) in large.enumerated() {
                let row = k / columns, column = k % columns
                frames[i] = Frame(x: (margin + Double(column) * (cellWidth + gap)).rounded(),
                                  y: (top + Double(row) * (cellHeight + gap)).rounded(),
                                  width: cellWidth.rounded(down: true), height: cellHeight.rounded(down: true))
            }
        }
        return frames.map { $0 ?? Frame(x: margin, y: margin, width: 200, height: 120) }
    }
}

private extension Double {
    func rounded(down: Bool) -> Double { down ? Foundation.floor(self) : self.rounded() }
}
