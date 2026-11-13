import Foundation
import CoreGraphics
import FacetCore

/// One row of the Gantt chart.
struct CmpGanttTask {
    var row: Int
    var name: String
    var start: Date
    /// End used for drawing (date-only ends are extended to the end of that day when `inclusiveEnd`).
    var end: Date
    /// 0…1, nil when no progress field.
    var progress: Double?
    var isMilestone: Bool
    var group: Int
    var colorHex: String
    var selection: DataPointSelection?
    var tooltip: CmpMapTooltipContent
}

/// Builds Gantt tasks from `VisualData` (wells: task, start, end, progress, legend, tooltips).
struct CmpGanttModel {
    var tasks: [CmpGanttTask] = []
    var legend: [(label: String, colorHex: String)] = []
    var legendTitle = ""
    var taskTitle = "Task"
    var hasFields = false
    /// Padded time range shown at zoom 1.
    var rangeStart = Date()
    var rangeEnd = Date()

    init(env: CmpEnv) {
        let data = env.data, theme = env.theme, f = env.f
        guard let startCol = data.indices(.start).first else { return }
        let taskCol = data.indices(.task).first
        let endCol = data.indices(.end).first
        let progCol = data.indices(.progress).first
        let legCol = data.indices(.legend).first
        hasFields = true
        if let tc = taskCol { taskTitle = env.caption(tc) }
        let baseHex = f.string("gantt", "barColor", theme.dataColors.first ?? theme.accent)
        let inclusive = f.bool("gantt", "inclusiveEnd", true)

        var legendValues: [Value] = []
        if let lc = legCol {
            var seen = Set<Value>()
            for v in data.table.columns[lc].values where seen.insert(v).inserted { legendValues.append(v) }
            legendTitle = env.caption(lc)
            legend = legendValues.enumerated().map { i, v in
                (ValueFormatter.format(v, data.formats[safe: lc] ?? ""), theme.dataColors.isEmpty ? baseHex : theme.dataColors[i % theme.dataColors.count])
            }
        }
        // Progress may be a fraction (0…1) or a percentage (0…100).
        let progressMax = progCol.flatMap { CmpConditionalFormat.range(data.table.columns[$0].values)?.max } ?? 1
        let progressScale = progressMax > 1.5 ? 100.0 : 1.0
        let selectionColumns = data.indices(.task) + data.indices(.legend)

        for r in 0..<data.table.rowCount {
            guard let rawStart = data.table[r, startCol].asDate else { continue }
            var start = rawStart
            var end = endCol.flatMap { data.table[r, $0].asDate } ?? rawStart
            if end < start { swap(&start, &end) }
            let milestone = end == start
            if !milestone, inclusive, end.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) == 0 {
                end = end.addingTimeInterval(86400)
            }
            var progress: Double?
            if let pc = progCol, let p = data.table[r, pc].asDouble, p.isFinite { progress = max(0, min(1, p / progressScale)) }
            var hex = baseHex, group = 0
            if let lc = legCol, let i = legendValues.firstIndex(of: data.table[r, lc]) { hex = legend[i].colorHex; group = i }
            let name = taskCol.map { data.formatted(row: r, col: $0) } ?? "Task \(r + 1)"
            var tip = CmpMapTooltipContent.forRow(r, env: env, titleColumn: taskCol)
            if taskCol == nil { tip.title = name }
            if !milestone {
                tip.rows.append(["Duration", CmpGanttScale.durationText(from: start, to: end)])
            }
            if let pc = progCol, let progress, let i = tip.rows.firstIndex(where: { $0[0] == env.caption(pc) }) {
                tip.rows[i][1] = "\(Int((progress * 100).rounded()))%"
            }
            tasks.append(CmpGanttTask(row: r, name: name, start: start, end: end, progress: progress, isMilestone: milestone,
                                      group: group, colorHex: hex,
                                      selection: CmpSelection.point(data, row: r, columns: selectionColumns), tooltip: tip))
        }
        guard let lo = tasks.map(\.start).min(), let hi = tasks.map(\.end).max() else { return }
        let span = max(hi.timeIntervalSince(lo), 86400)
        let pad = max(86400 * 0.5, span * 0.03)
        rangeStart = lo.addingTimeInterval(-pad)
        rangeEnd = hi.addingTimeInterval(pad)
    }
}

/// Adaptive time axis: picks day / week / month / quarter / year cells from the pixel density.
enum CmpGanttScale {
    enum Unit: String { case day, week, month, quarter, year }

    /// The finest unit whose cells stay wide enough to label at `pixelsPerDay`.
    static func unit(pixelsPerDay: Double) -> Unit {
        if pixelsPerDay >= 16 { return .day }
        if pixelsPerDay * 7 >= 44 { return .week }
        if pixelsPerDay * 30.4 >= 34 { return .month }
        if pixelsPerDay * 91.3 >= 30 { return .quarter }
        return .year
    }

    /// The grouping tier drawn above `unit` (nil for years).
    static func major(for unit: Unit) -> Unit? {
        switch unit {
        case .day, .week: return .month
        case .month, .quarter: return .year
        case .year: return nil
        }
    }

    /// Start of the unit containing `date` (UTC; weeks start on Monday).
    static func floor(_ date: Date, to unit: Unit) -> Date {
        let cal = Calendar.utc
        let day = cal.startOfDay(for: date)
        switch unit {
        case .day: return day
        case .week:
            let weekday = cal.component(.weekday, from: day)   // 1 = Sunday
            return cal.date(byAdding: .day, value: -((weekday + 5) % 7), to: day) ?? day
        case .month:
            return cal.date(from: cal.dateComponents([.year, .month], from: day)) ?? day
        case .quarter:
            var c = cal.dateComponents([.year, .month], from: day)
            c.month = (((c.month ?? 1) - 1) / 3) * 3 + 1
            return cal.date(from: c) ?? day
        case .year:
            return cal.date(from: cal.dateComponents([.year], from: day)) ?? day
        }
    }

    static func next(_ date: Date, _ unit: Unit) -> Date {
        let cal = Calendar.utc
        switch unit {
        case .day: return cal.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86400)
        case .week: return cal.date(byAdding: .day, value: 7, to: date) ?? date.addingTimeInterval(7 * 86400)
        case .month: return cal.date(byAdding: .month, value: 1, to: date) ?? date.addingTimeInterval(30 * 86400)
        case .quarter: return cal.date(byAdding: .month, value: 3, to: date) ?? date.addingTimeInterval(91 * 86400)
        case .year: return cal.date(byAdding: .year, value: 1, to: date) ?? date.addingTimeInterval(365 * 86400)
        }
    }

    /// Unit boundaries covering `from`…`to`: the first is ≤ `from`, the last is ≥ `to`.
    static func ticks(_ unit: Unit, from: Date, to: Date) -> [Date] {
        var out: [Date] = []
        var d = floor(from, to: unit)
        var guardCount = 0
        while guardCount < 20_000 {
            out.append(d)
            if d >= to { break }
            d = next(d, unit)
            guardCount += 1
        }
        return out
    }

    /// Cell label; `width` is the cell width in points so longer forms are used when they fit.
    static func label(_ unit: Unit, _ date: Date, width: CGFloat, isMajor: Bool = false) -> String {
        switch unit {
        case .day: return DateParsing.string(date, format: width >= 40 ? "EEE d" : "d")
        case .week: return DateParsing.string(date, format: "d MMM")
        case .month:
            if isMajor { return DateParsing.string(date, format: width >= 96 ? "MMMM yyyy" : "MMM yyyy") }
            return DateParsing.string(date, format: width >= 76 ? "MMMM" : (width >= 30 ? "MMM" : "MMMMM"))
        case .quarter:
            let m = Calendar.utc.component(.month, from: date)
            return "Q\((m - 1) / 3 + 1)"
        case .year: return DateParsing.string(date, format: width >= 34 ? "yyyy" : "''yy")
        }
    }

    static func durationText(from: Date, to: Date) -> String {
        let seconds = to.timeIntervalSince(from)
        if seconds < 86400 {
            let h = seconds / 3600
            return h == h.rounded() ? "\(Int(h)) hour\(Int(h) == 1 ? "" : "s")" : String(format: "%.1f hours", h)
        }
        let days = Int((seconds / 86400).rounded())
        return "\(days) day\(days == 1 ? "" : "s")"
    }
}

/// Maps dates to x positions over a content width.
struct CmpGanttAxis {
    let start: Date
    let end: Date
    let width: CGFloat

    var pixelsPerDay: Double { Double(width) / max(1e-6, end.timeIntervalSince(start) / 86400) }
    var unit: CmpGanttScale.Unit { CmpGanttScale.unit(pixelsPerDay: pixelsPerDay) }
    func x(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / max(1, end.timeIntervalSince(start))) * width
    }
}
