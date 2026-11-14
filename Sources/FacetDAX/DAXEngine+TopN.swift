import Foundation
import FacetCore

extension DAXEngine {
    /// The values a Top N filter keeps: the `count` values of the filter column with the largest
    /// (or, for Bottom N, smallest) aggregated by-field, plus every value tied with the last one kept.
    ///
    /// Equivalent to `TOPN(count, ALL(column), CALCULATE(<by>), DESC | ASC)`: each candidate value
    /// (the blank member included) is scored with the by-field evaluated under a filter on that
    /// value alone, so relationships carry the value to a by-field in another table and other
    /// filters of the visual do not change which values are kept.
    func topNValues(of cid: ColumnID, count: Int, by: FieldRef, bottom: Bool) throws -> Set<Value> {
        guard count > 0 else { return [] }
        let score = try topNScore(by)
        let candidates = distinctValues(cid, FilterContext(db: db), blankRow: true)
        var keys: [[Value]] = []
        keys.reserveCapacity(candidates.count)
        for v in candidates {
            let ctx = Ctx(fc: FilterContext(db: db, filters: [CtxFilter.single(cid, v)]))
            keys.append([DAXEngine.normKey(try score(ctx))])
        }
        let order = DAXEngine.sortedIndices(keys, descending: [!bottom])
        var take = min(count, order.count)
        while take < order.count, take > 0, keys[order[take]] == keys[order[take - 1]] { take += 1 }
        return Set(order.prefix(take).map { candidates[$0] })
    }

    /// The by-field of a Top N filter as a function of the filter context: a measure, or a column
    /// under its aggregation (the field's own, else the column's default summarisation, else
    /// sum for numbers and count for everything else).
    private func topNScore(_ by: FieldRef) throws -> (Ctx) throws -> Value {
        switch by.kind {
        case .measure:
            guard let measure = lookupMeasure(by.name.daxKey) else {
                throw DAXError("The Top N filter orders by measure [\(by.name)], which does not exist.")
            }
            return { [unowned self] ctx in try self.evalMeasure(measure, ctx) }
        case .column:
            guard let byCid = columnID(by) else {
                throw DAXError("The Top N filter orders by column '\(by.table)'[\(by.name)], which does not exist.")
            }
            try checkColumnAccess(byCid, nil)
            let column = db.column(byCid)
            var aggregation = by.aggregation
            if aggregation == .none { aggregation = column.model?.summarizeBy ?? .none }
            if aggregation == .none { aggregation = column.type.isNumeric ? .sum : .count }
            let function: String
            switch aggregation {
            case .first: function = "MIN"
            case .last: function = "MAX"
            default: function = aggregation.daxFunction ?? "SUM"
            }
            let reference = Node(.column(table: db.tables[byCid.table].name, name: column.name, sub: nil), 0..<0)
            let node = Node(.call(function, [reference]), 0..<0)
            return { [unowned self] ctx in try self.scalar(node, ctx) }
        }
    }
}
