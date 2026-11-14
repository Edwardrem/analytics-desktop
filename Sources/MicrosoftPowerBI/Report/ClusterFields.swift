import Foundation
import FacetCore
import FacetAnalytics
import FacetVisuals

/// "Automatically find clusters", as Power BI offers it on a scatter chart or a table: the members
/// of a field (the scatter chart's Details, or a column of the table) are clustered on the visual's
/// numbers — X, Y and Size, or every number column of the table — and the clusters become a new
/// field of the model. The field is a list group over the source column ("Cluster 1", "Cluster 2", …),
/// so it can be edited as a group and used in any visual; the visual gets it at once, and adding
/// the field and placing it are one undo step.
enum ClusterFields {
    static let supportedTypes: Set<VisualType> = [.scatter, .table]
    /// Most clusters asked for, and most tried when the count is found automatically.
    static let maxClusters = 20
    static let maxAutomatic = 10
    /// Where members without numbers for every measure go.
    static let otherGroupName = "Other"

    /// What one clustering works on.
    struct Plan {
        var visualID: UUID
        var visualType: VisualType
        /// The visual's columns whose members can be clustered (Details on a scatter chart).
        var candidates: [FieldRef]
        /// The numbers the members are clustered on.
        var measures: [FieldRef]
    }

    /// The clustering a visual offers. Nil unless it's a scatter chart with Details, X and Y, or a
    /// table with a column and a number.
    static func plan(spec: VisualSpec, model: SemanticModel) -> Plan? {
        var candidates: [FieldRef], measures: [FieldRef]
        switch spec.type {
        case .scatter:
            guard !spec.fields(.x).isEmpty, !spec.fields(.y).isEmpty else { return nil }
            candidates = spec.fields(.details)
            measures = spec.fields(.x) + spec.fields(.y) + spec.fields(.size)
        case .table:
            candidates = spec.fields(.values)
            measures = spec.fields(.values)
        default:
            return nil
        }
        candidates = candidates.filter { f in f.kind == .column && !f.isAggregate && model.table(f.table)?.column(f.name) != nil }
        var seen = Set<String>()
        measures = measures.filter { $0.isAggregate && seen.insert($0.key).inserted }
        guard !candidates.isEmpty, !measures.isEmpty else { return nil }
        return Plan(visualID: spec.id, visualType: spec.type, candidates: candidates, measures: measures)
    }

    /// "Store (clusters)", numbered when the table already has that name.
    static func defaultName(for field: FieldRef, model: SemanticModel) -> String {
        let base = "\(field.name) (clusters)"
        let taken = model.table(field.table).map { $0.columns.map(\.name) + $0.measures.map(\.name) } ?? []
        var name = base, n = 2
        while taken.contains(where: { ModelDAX.same($0, name) }) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    /// What stops the field from being added, in words; empty when it can be.
    static func problems(name raw: String, field: FieldRef, model: SemanticModel) -> [String] {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let table = model.table(field.table), table.column(field.name) != nil else {
            return ["The column “\(field.name)” is no longer in the model."]
        }
        if name.isEmpty { return ["Name the clusters."] }
        if name.contains("[") || name.contains("]") { return ["Names can't contain square brackets."] }
        if table.column(name) != nil { return ["A column named “\(name)” already exists in \(table.name)."] }
        if table.measure(name) != nil { return ["“\(name)” is already a measure in \(table.name)."] }
        return []
    }

    // MARK: Clustering

    /// The members of `field` and their numbers, from the engine under the visual's request. A
    /// member without a number for every measure isn't a point.
    static func points(field: FieldRef, measures: [FieldRef], request: VisualRequest,
                       engine: CalculationService) -> (members: [Value], points: [[Double]], skipped: Int) {
        var spec = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 1, height: 1))
        var group = FieldRef.column(field.table, field.name)
        group.aggregation = .none
        spec.setFields(.category, [group])
        spec.setFields(.values, measures)
        var r = request
        r.crossFilters += r.highlights
        r.highlights = []
        r.rowLimit = 0
        let result = engine.visualData(spec: spec, request: r)
        let t = result.table
        guard result.error == nil, let mc = result.indices(.category).first, mc < t.columnCount else { return ([], [], 0) }
        let valueColumns = result.indices(.values).filter { $0 < t.columnCount }
        guard valueColumns.count == measures.count else { return ([], [], 0) }
        var members: [Value] = [], points: [[Double]] = [], skipped = 0
        for row in 0..<t.rowCount {
            let numbers = valueColumns.compactMap { c -> Double? in
                let v = t[row, c]
                guard v.isNumber, let d = v.asDouble, d.isFinite else { return nil }
                return d
            }
            guard numbers.count == valueColumns.count else { skipped += 1; continue }
            members.append(t[row, mc])
            points.append(numbers)
        }
        return (members, points, skipped)
    }

    /// The clusters as a list group over the source column: "Cluster 1" is the largest. `k` nil
    /// finds the number of clusters that separates the members best.
    static func grouping(source: String, members: [Value], points: [[Double]], clusters k: Int?) throws -> ColumnGrouping {
        guard members.count == points.count else { throw ClusteringError.raggedInput }
        let result = try KMeans.cluster(points: points, k: k.map { min(max($0, 1), maxClusters) }, maxK: maxAutomatic)
        var g = ColumnGrouping(kind: .list, sourceColumn: source)
        for (i, cluster) in result.assignments.enumerated() where members.indices.contains(i) && cluster >= 0 {
            g.groups["Cluster \(cluster + 1)", default: []].append(members[i])
        }
        g.otherGroupName = otherGroupName
        return g
    }

    /// The new model column holding the clusters.
    static func column(name: String, description: String, grouping: ColumnGrouping) -> ModelColumn {
        var c = ModelColumn(name: name.trimmingCharacters(in: .whitespacesAndNewlines), dataType: .text)
        c.summarizeBy = .none
        c.grouping = grouping
        c.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return c
    }

    /// Adds the cluster column to the source's table and puts it on the visual: the scatter chart's
    /// Legend, or the table's column after the source.
    static func apply(_ column: ModelColumn, table: String, source: FieldRef, visualID: UUID, to d: inout FacetDocument) {
        guard let ti = d.model.tableIndex(table) else { return }
        d.model.tables[ti].columns.append(column)
        let field = FieldRef.column(d.model.tables[ti].name, column.name)
        for p in d.report.pages.indices {
            guard let v = d.report.pages[p].visuals.firstIndex(where: { $0.id == visualID }) else { continue }
            var spec = d.report.pages[p].visuals[v]
            switch spec.type {
            case .scatter:
                spec.setFields(.legend, [field])
            case .table:
                var columns = spec.fields(.values)
                let at = columns.firstIndex { !$0.isAggregate && $0.kind == .column && ModelDAX.same($0.table, source.table)
                    && ModelDAX.same($0.name, source.name) }.map { $0 + 1 } ?? columns.count
                columns.insert(field, at: min(at, columns.count))
                spec.setFields(.values, columns)
            default:
                break
            }
            d.report.pages[p].visuals[v] = spec
        }
    }
}

// MARK: - Store

extension DocumentStore {
    /// Opens Automatically find clusters for a scatter chart or table on the current page.
    func findClusters(in visualID: UUID) {
        guard let spec = currentPage.visual(visualID), let plan = ClusterFields.plan(spec: spec, model: model) else {
            status = StatusMessage(kind: .info, text: "Clusters are found on a scatter chart with Details, X and Y, or on a table with a column and a number.")
            return
        }
        let request = self.request(for: spec, on: currentPage)
        present { ClusterSheet(session: ClusterSession(store: self, plan: plan, request: request)) }
    }

    /// Adds a cluster column and places it on the visual, as one undo step.
    func addClusterField(_ column: ModelColumn, source: FieldRef, visualID: UUID) {
        mutate("Find Clusters", invalidates: .model) { d in
            ClusterFields.apply(column, table: source.table, source: source, visualID: visualID, to: &d)
        }
    }
}
