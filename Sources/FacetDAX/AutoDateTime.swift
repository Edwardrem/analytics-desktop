import Foundation
import FacetCore

/// Auto date/time, as Power BI Desktop defines it: when the model's option is on, every date column
/// gets a hidden calendar with a Year › Quarter › Month › Day hierarchy, provided that
/// - its table is imported (not DirectQuery or Dual) and not marked as a date table, and
/// - the column is not on the "many" side of a relationship.
///
/// DAX reaches the calendar as `'Table'[Date].[Year]` (also `[QuarterNo]`, `[Quarter]`, `[MonthNo]`,
/// `[Month]`, `[Day]` and `[Date]`); report fields use `FieldRef.dateLevel`.
public enum AutoDateTime {
    /// The levels of the date hierarchy, top first.
    public static let levels = ["Year", "Quarter", "Month", "Day"]

    /// True when the model gives this column a date hierarchy.
    public static func isEligible(table: ModelTable, column: ModelColumn, model: SemanticModel) -> Bool {
        guard model.autoDateTime, column.dataType.isTemporal, table.storageMode == .import, table.dateColumn == nil else { return false }
        return !isManySide(table: table.name, column: column.name, model: model)
    }

    /// Every column that has a date hierarchy, as (table, column) names.
    public static func eligibleColumns(in model: SemanticModel) -> [(table: String, column: String)] {
        guard model.autoDateTime else { return [] }
        return model.tables.flatMap { t in
            t.columns.filter { isEligible(table: t, column: $0, model: model) }.map { (t.name, $0.name) }
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    /// The many side of a relationship: `from` of many-to-one, `to` of one-to-many, both of many-to-many.
    static func isManySide(table: String, column: String, model: SemanticModel) -> Bool {
        model.relationships.contains { r in
            let isFrom = same(r.fromTable, table) && same(r.fromColumn, column)
            let isTo = same(r.toTable, table) && same(r.toColumn, column)
            switch r.cardinality {
            case .manyToOne: return isFrom
            case .oneToMany: return isTo
            case .manyToMany: return isFrom || isTo
            case .oneToOne: return false
            }
        }
    }

    /// Month names in the model's language, January first.
    static func monthNames(culture: String) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: culture.isEmpty ? "en-US" : culture)
        let names = f.standaloneMonthSymbols ?? []
        return names.count == 12 ? names : ["January", "February", "March", "April", "May", "June", "July",
                                            "August", "September", "October", "November", "December"]
    }
}

extension DAXEngine {
    /// Appends the hidden hierarchy columns of every eligible date column when auto date/time is on:
    /// stored columns, or calculated ones. They are named `Column.Level`, left out of table expressions
    /// and reached as `Column.[Level]`; a rebuild replaces them.
    func buildAutoDateColumns(calculated: Bool) {
        guard model.autoDateTime else { return }
        let cal = Calendar.utc
        let months = AutoDateTime.monthNames(culture: model.culture)
        let levels: [(String, DataType, (Date) -> Value)] = [
            ("Year", .integer, { .int(Int64(cal.component(.year, from: $0))) }),
            // Calendar's .quarter component is unreliable; the quarter follows from the month.
            ("QuarterNo", .integer, { .int(Int64((cal.component(.month, from: $0) - 1) / 3 + 1)) }),
            ("Quarter", .text, { .string("Qtr \((cal.component(.month, from: $0) - 1) / 3 + 1)") }),
            ("MonthNo", .integer, { .int(Int64(cal.component(.month, from: $0))) }),
            ("Month", .text, { d in .string(months[safe: cal.component(.month, from: d) - 1] ?? "") }),
            ("Day", .integer, { .int(Int64(cal.component(.day, from: $0))) }),
        ]
        for ti in db.tables.indices {
            guard let mt = db.tables[ti].model else { continue }
            for c in mt.columns where c.isCalculated == calculated && AutoDateTime.isEligible(table: mt, column: c, model: model) {
                guard let cid = db.tables[ti].colIndex[c.name.daxKey] else { continue }
                let values = db.tables[ti].columns[cid].values
                var map: [String: ColumnID] = ["date": ColumnID(table: ti, col: cid)]
                for (level, type, make) in levels {
                    let name = "\(c.name).\(level)"
                    // A real column with that name wins.
                    if let existing = db.tables[ti].colIndex[name.daxKey], !db.tables[ti].variationColumns.contains(existing) { continue }
                    let out = values.map { v -> Value in v.asDate.map(make) ?? .null }
                    db.tables[ti].addColumn(ColumnStore(computed: name, type: type, values: out, model: nil))
                    if let newCid = db.tables[ti].colIndex[name.daxKey] {
                        map[level.lowercased()] = ColumnID(table: ti, col: newCid)
                        db.tables[ti].variationColumns.insert(newCid)
                    }
                }
                autoDateColumns[ColumnID(table: ti, col: cid)] = map
                autoDateTables.insert(ti)
            }
        }
    }

    /// The engine column a report field refers to: the column itself, or its date hierarchy level.
    func columnID(_ field: FieldRef) -> ColumnID? {
        guard let cid = db.columnID(table: field.table, column: field.name) else { return nil }
        guard let level = field.dateLevel else { return cid }
        return autoDateColumns[cid]?[level.daxKey]
    }
}
