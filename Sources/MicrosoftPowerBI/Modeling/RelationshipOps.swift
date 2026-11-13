import SwiftUI
import FacetCore

/// Pure relationship logic: cardinality detection, type compatibility, ambiguity, autodetect.
enum RelationshipLogic {
    /// True when no non-blank value repeats.
    static func isUnique(_ values: [Value]) -> Bool {
        var seen = Set<Value>()
        seen.reserveCapacity(min(values.count, 1 << 16))
        for v in values where !v.isNull { if !seen.insert(v).inserted { return false } }
        return true
    }
    static func distinctCount(_ values: [Value]) -> Int { Set(values).count }

    /// Cardinality implied by the data on each side.
    static func cardinality(fromUnique: Bool, toUnique: Bool) -> Cardinality {
        switch (fromUnique, toUnique) {
        case (false, true): return .manyToOne
        case (true, false): return .oneToMany
        case (true, true): return .oneToOne
        case (false, false): return .manyToMany
        }
    }

    private static func family(_ t: DataType) -> Int {
        switch t {
        case .integer, .decimal, .currency, .duration: return 1
        case .date, .dateTime, .time: return 2
        case .text: return 3
        case .boolean: return 4
        case .binary: return 5
        case .any: return 0
        }
    }
    /// Columns can be related when their types are in the same family (number, date, text, true/false).
    static func compatible(_ a: DataType, _ b: DataType) -> Bool {
        let fa = family(a), fb = family(b)
        if fa == 5 || fb == 5 { return false }
        return fa == 0 || fb == 0 || fa == fb
    }

    /// True when the two tables are already connected by active relationships other than `excluding`.
    static func hasActivePath(_ model: SemanticModel, from a: String, to b: String, excluding: UUID? = nil) -> Bool {
        var adjacency: [String: [String]] = [:]
        for r in model.relationships where r.isActive && r.id != excluding {
            adjacency[r.fromTable.lowercased(), default: []].append(r.toTable.lowercased())
            adjacency[r.toTable.lowercased(), default: []].append(r.fromTable.lowercased())
        }
        let start = a.lowercased(), goal = b.lowercased()
        if start == goal { return false }
        var visited: Set<String> = [start]
        var queue = [start]
        while let t = queue.popLast() {
            for next in adjacency[t] ?? [] where !visited.contains(next) {
                if next == goal { return true }
                visited.insert(next); queue.append(next)
            }
        }
        return false
    }

    /// A relationship between the same two columns (in either direction), if one exists.
    static func existing(_ model: SemanticModel, _ r: Relationship) -> Relationship? {
        model.relationships.first { e in
            e.id != r.id && ((ModelDAX.same(e.fromTable, r.fromTable) && ModelDAX.same(e.fromColumn, r.fromColumn) && ModelDAX.same(e.toTable, r.toTable) && ModelDAX.same(e.toColumn, r.toColumn))
                || (ModelDAX.same(e.fromTable, r.toTable) && ModelDAX.same(e.fromColumn, r.toColumn) && ModelDAX.same(e.toTable, r.fromTable) && ModelDAX.same(e.toColumn, r.fromColumn)))
        }
    }

    /// Problems that stop a relationship being created, or nil.
    static func problem(_ r: Relationship, model: SemanticModel) -> String? {
        if r.fromTable.isEmpty || r.toTable.isEmpty || r.fromColumn.isEmpty || r.toColumn.isEmpty { return "Choose a column in each table." }
        if ModelDAX.same(r.fromTable, r.toTable) { return "A relationship needs two different tables." }
        guard let a = model.table(r.fromTable)?.column(r.fromColumn), let b = model.table(r.toTable)?.column(r.toColumn) else { return "Choose a column in each table." }
        if !compatible(a.dataType, b.dataType) {
            return "\(r.fromColumn) is \(a.dataType.displayName.lowercased()) and \(r.toColumn) is \(b.dataType.displayName.lowercased()). Related columns need matching data types."
        }
        if existing(model, r) != nil { return "These two columns are already related." }
        return nil
    }

    /// Builds a relationship between two columns, orienting it many → one from the data.
    static func make(_ model: SemanticModel, data: DataStore, tableA: String, columnA: String, tableB: String, columnB: String) -> (relationship: Relationship, warning: String?) {
        let aUnique = data[tableA]?.column(columnA).map { isUnique($0.values) } ?? false
        let bUnique = data[tableB]?.column(columnB).map { isUnique($0.values) } ?? false
        var r: Relationship
        var warning: String?
        switch (aUnique, bUnique) {
        case (true, false):
            r = Relationship(fromTable: tableB, fromColumn: columnB, toTable: tableA, toColumn: columnA)
        case (false, true):
            r = Relationship(fromTable: tableA, fromColumn: columnA, toTable: tableB, toColumn: columnB)
        case (true, true):
            r = Relationship(fromTable: tableA, fromColumn: columnA, toTable: tableB, toColumn: columnB)
            r.cardinality = .oneToOne; r.crossFilter = .both
        case (false, false):
            r = Relationship(fromTable: tableA, fromColumn: columnA, toTable: tableB, toColumn: columnB)
            r.cardinality = .manyToMany
            warning = "Neither column has unique values, so this is a many-to-many relationship. Totals can be counted more than once."
        }
        if hasActivePath(model, from: r.fromTable, to: r.toTable) {
            r.isActive = false
            warning = "\(r.fromTable) and \(r.toTable) are already connected, so the new relationship is inactive. Use USERELATIONSHIP to switch it on in a measure."
        }
        return (r, warning)
    }

    /// Proposes relationships between columns with equal names and compatible types where one side is unique.
    static func autodetect(_ model: SemanticModel, data: DataStore) -> [Relationship] {
        var working = model
        var found: [Relationship] = []
        var uniqueCache: [String: Bool] = [:]
        func unique(_ table: String, _ column: String) -> Bool {
            let key = "\(table)\u{1F}\(column)".lowercased()
            if let u = uniqueCache[key] { return u }
            let u = data[table]?.column(column).map { !$0.values.isEmpty && isUnique($0.values) } ?? false
            uniqueCache[key] = u
            return u
        }
        func keyScore(_ name: String) -> Int {
            let l = name.lowercased()
            return (l.hasSuffix("id") || l.hasSuffix("key") || l.hasSuffix("code") || l.hasSuffix("number")) ? 0 : 1
        }
        let tables = model.tables.filter { !$0.isHidden || true }
        for i in tables.indices {
            for j in tables.indices where j > i {
                let a = tables[i], b = tables[j]
                if working.relationships.contains(where: { (ModelDAX.same($0.fromTable, a.name) && ModelDAX.same($0.toTable, b.name)) || (ModelDAX.same($0.fromTable, b.name) && ModelDAX.same($0.toTable, a.name)) }) { continue }
                let candidates = a.columns.compactMap { ca -> (ModelColumn, ModelColumn)? in
                    guard let cb = b.column(ca.name), compatible(ca.dataType, cb.dataType), ca.dataType != .binary else { return nil }
                    return (ca, cb)
                }.sorted { keyScore($0.0.name) < keyScore($1.0.name) }
                for (ca, cb) in candidates {
                    let ua = unique(a.name, ca.name), ub = unique(b.name, cb.name)
                    guard ua || ub else { continue }
                    var r: Relationship
                    if ua && ub {
                        r = Relationship(fromTable: a.name, fromColumn: ca.name, toTable: b.name, toColumn: cb.name)
                        r.cardinality = .oneToOne; r.crossFilter = .both
                    } else if ub {
                        r = Relationship(fromTable: a.name, fromColumn: ca.name, toTable: b.name, toColumn: cb.name)
                    } else {
                        r = Relationship(fromTable: b.name, fromColumn: cb.name, toTable: a.name, toColumn: ca.name)
                    }
                    if hasActivePath(working, from: r.fromTable, to: r.toTable) { continue }
                    working.relationships.append(r)
                    found.append(r)
                    break
                }
            }
        }
        return found
    }
}

@MainActor
enum RelationshipOps {
    /// Creates a relationship between two columns, detecting cardinality from the data off the main thread.
    static func create(_ store: DocumentStore, tableA: String, columnA: String, tableB: String, columnB: String) {
        let model = store.model
        let probe = Relationship(fromTable: tableA, fromColumn: columnA, toTable: tableB, toColumn: columnB)
        if let problem = RelationshipLogic.problem(probe, model: model) {
            store.status = StatusMessage(kind: .warning, text: problem)
            return
        }
        let data = store.computedData.tables.isEmpty ? store.doc.data : store.computedData
        Task {
            let (r, warning) = await Task.detached(priority: .userInitiated) {
                RelationshipLogic.make(model, data: data, tableA: tableA, columnA: columnA, tableB: tableB, columnB: columnB)
            }.value
            store.updateModel("New Relationship") { $0.relationships.append(r) }
            store.modeling.select(.relationship(r.id))
            if let warning { store.status = StatusMessage(kind: .warning, text: warning) }
            else { store.status = StatusMessage(kind: .success, text: "Related \(r.fromTable)[\(r.fromColumn)] to \(r.toTable)[\(r.toColumn)] — \(r.cardinality.displayName.lowercased()).") }
        }
    }

    /// Finds and adds relationships between like-named columns.
    static func autodetect(_ store: DocumentStore) {
        let model = store.model
        let data = store.computedData.tables.isEmpty ? store.doc.data : store.computedData
        Task {
            let found = await Task.detached(priority: .userInitiated) { RelationshipLogic.autodetect(model, data: data) }.value
            if found.isEmpty {
                store.status = StatusMessage(kind: .info, text: "No new relationships found.")
            } else {
                store.updateModel("Autodetect Relationships") { $0.relationships.append(contentsOf: found) }
                store.status = StatusMessage(kind: .success, text: "Found \(found.count) new relationship\(found.count == 1 ? "" : "s").")
            }
        }
    }

    /// Short "Sales[ProductID] → Product[ProductID]" caption.
    static func caption(_ r: Relationship) -> String { "\(r.fromTable)[\(r.fromColumn)] → \(r.toTable)[\(r.toColumn)]" }
}
