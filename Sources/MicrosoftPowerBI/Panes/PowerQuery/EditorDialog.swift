import Foundation
import FacetCore
import FacetQuery

/// Every dialog the Power Query Editor shows. Commands set `QueryEditorSession.dialog`; the editor view presents it.
enum EditorDialog: Identifiable {
    /// Keep / remove top, bottom, range or alternate rows.
    case rows(RowsKind)
    case filter(column: String)
    case chooseColumns
    case goToColumn
    case renameColumn(String)
    case changeTypeWithLocale(columns: [String])
    /// "Change Column Type": the selected Changed Type step already converts a column; replace or add a step.
    case changeTypeStep(TypeStepChange)
    case replaceValues(columns: [String])
    case replaceErrors(columns: [String])
    case split(column: String, SplitKind)
    case mergeColumns(columns: [String], asNewColumn: Bool)
    case affix(columns: [String], suffix: Bool)
    case extract(columns: [String], ExtractKind, asNewColumn: Bool)
    case numberValue(columns: [String], NumberValueKind, asNewColumn: Bool)
    case extractValues(column: String)
    case groupBy
    case pivot(column: String)
    case merge(asNew: Bool)
    case append(asNew: Bool)
    case customColumn
    case conditionalColumn
    case indexColumn
    case invokeFunction
    case columnFromExamples(columns: [String]?)
    case expand(column: String)
    case aggregate(column: String)
    case script(python: Bool)
    /// The gear of an applied step: its settings dialog, filled from the step.
    case editStep(StepEdit)
    case sourceSettings(step: Int)
    case advancedEditor
    case queryProperties(UUID)
    case renameQuery(UUID)
    case createFunction(UUID)
    case newGroup(moving: Set<UUID>)
    case renameGroup(String)
    case manageParameters(select: UUID?)
    case dependencies
    case diagnostics([QueryDiagnosticEvent], title: String)
    case nativeQuery(String)
    case columnProfile
    // Get Data from inside the editor.
    case newSource, enterData, recentSources, dataSourceSettings
    case connect(connectorID: String, location: String)

    var id: String {
        switch self {
        case .rows(let k): return "rows.\(k)"
        case .filter(let c): return "filter.\(c)"
        case .split(let c, let k): return "split.\(c).\(k)"
        case .extract(let c, let k, let n): return "extract.\(c).\(k).\(n)"
        case .numberValue(let c, let k, let n): return "number.\(c).\(k).\(n)"
        case .editStep(let e): return "edit.\(e.index)"
        case .diagnostics(_, let t): return "diagnostics.\(t)"
        default: return String(describing: self)
        }
    }

    enum RowsKind: String, CaseIterable { case keepTop, keepBottom, keepRange, removeTop, removeBottom, removeAlternate }
    enum SplitKind: String { case delimiter, length, positions }
    enum ExtractKind: String { case first, last, range, before, after, between }
    enum NumberValueKind: String {
        case add, subtract, multiply, divide, integerDivide, modulo, percentage, percentOf, power, round

        var title: String {
            switch self {
            case .add: return "Add"
            case .subtract: return "Subtract"
            case .multiply: return "Multiply"
            case .divide: return "Divide"
            case .integerDivide: return "Integer-Divide"
            case .modulo: return "Modulo"
            case .percentage: return "Percentage"
            case .percentOf: return "Percent Of"
            case .power: return "Power"
            case .round: return "Round"
            }
        }
        func operation(_ value: Double) -> NumberOperation {
            switch self {
            case .add: return .add(value)
            case .subtract: return .subtract(value)
            case .multiply: return .multiply(value)
            case .divide: return .divide(value)
            case .integerDivide: return .integerDivide(value)
            case .modulo: return .modulo(value)
            case .percentage: return .percentage(value)
            case .percentOf: return .percentOf(value)
            case .power: return .power(value)
            case .round: return .round(digits: Int(value))
            }
        }
    }
}

/// A type change meeting a selected Changed Type step with the same locale.
struct TypeStepChange {
    var stepIndex: Int
    var previous: String
    var existing: [(column: String, type: DataType)]
    var changes: [(column: String, type: DataType)]
    var culture: String?

    /// Whether the step already converts one of the columns (Power Query asks before replacing it).
    var clashes: Bool { changes.contains { c in existing.contains { $0.column == c.column } } }
    /// The step's conversions with the new ones: a column it already converts takes its new type in place.
    var merged: [(column: String, type: DataType)] {
        var out = existing
        for c in changes {
            if let i = out.firstIndex(where: { $0.column == c.column }) { out[i].type = c.type } else { out.append(c) }
        }
        return out
    }
}

/// An applied step opened from its gear: where it is, the step it reads, and its decoded settings.
struct StepEdit {
    var index: Int
    var previous: String
    var transform: Transform
}
