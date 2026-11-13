import Foundation
import AppKit
import FacetCore

/// Display units for axis and data labels.
public enum DisplayUnits: String, CaseIterable, Sendable {
    case auto, none, thousands, millions, billions, trillions

    /// Parses the format-pane value: "auto", "none", "K"/"thousands", "M"/"millions", "bn"/"billions", "T"/"trillions".
    public init(_ s: String) {
        switch s.lowercased() {
        case "none": self = .none
        case "k", "thousands": self = .thousands
        case "m", "millions": self = .millions
        case "bn", "b", "billions": self = .billions
        case "t", "trillions": self = .trillions
        default: self = .auto
        }
    }
    var divisor: Double {
        switch self { case .thousands: return 1e3; case .millions: return 1e6; case .billions: return 1e9; case .trillions: return 1e12; default: return 1 }
    }
    var suffix: String {
        switch self { case .thousands: return "K"; case .millions: return "M"; case .billions: return "bn"; case .trillions: return "T"; default: return "" }
    }
}

/// A resolved numeric axis: its domain and the tick values to label.
public struct AxisScale: Sendable {
    public var lower: Double
    public var upper: Double
    public var ticks: [Double]
    public var isLog = false
    public var span: Double { upper - lower }
    public init(lower: Double, upper: Double, ticks: [Double], isLog: Bool = false) {
        self.lower = lower; self.upper = upper; self.ticks = ticks; self.isLog = isLog
    }
}

/// Axis maths and label formatting shared by every chart.
public enum AxisFormatter {
    /// 1, 2, 2.5, 5 × 10ⁿ step at or above `rough`.
    public static func niceStep(_ rough: Double) -> Double {
        guard rough > 0, rough.isFinite else { return 1 }
        let mag = pow(10, floor(log10(rough)))
        let n = rough / mag
        let step: Double = n <= 1 ? 1 : (n <= 2 ? 2 : (n <= 2.5 ? 2.5 : (n <= 5 ? 5 : 10)))
        return step * mag
    }

    /// The 1, 2, 5 × 10ⁿ step closest to `rough` (used for axes, where a slightly denser scale beats wasted headroom).
    public static func nearestNiceStep(_ rough: Double) -> Double {
        guard rough > 0, rough.isFinite else { return 1 }
        let mag = pow(10, floor(log10(rough)))
        let n = rough / mag
        return (n < 1.5 ? 1 : (n < 3.5 ? 2 : (n < 7.5 ? 5 : 10))) * mag
    }

    /// A rounded axis range with evenly spaced ticks that contains the data.
    /// - Parameters:
    ///   - includeZero: anchor the axis at zero (bars); lines may pass false to zoom into the data.
    ///   - fixedMin / fixedMax: author-set bounds, which win over the data.
    ///   - targetTicks: desired tick count (reduce for small charts).
    ///   - log: logarithmic scale; ticks are powers of ten.
    public static func niceScale(dataMin: Double, dataMax: Double, includeZero: Bool = true, fixedMin: Double? = nil,
                                 fixedMax: Double? = nil, targetTicks: Int = 5, log: Bool = false) -> AxisScale {
        var lo = dataMin.isFinite ? dataMin : 0, hi = dataMax.isFinite ? dataMax : 1
        if lo > hi { swap(&lo, &hi) }
        if log {
            let positiveLo = max(fixedMin ?? lo, 1e-9)
            let l = floor(log10(positiveLo)), h = ceil(log10(max(fixedMax ?? hi, positiveLo * 10)))
            let ticks = stride(from: l, through: h, by: max(1, ((h - l) / Double(max(2, targetTicks))).rounded(.up))).map { pow(10, $0) }
            return AxisScale(lower: pow(10, l), upper: pow(10, h), ticks: ticks, isLog: true)
        }
        if includeZero { lo = min(lo, 0); hi = max(hi, 0) }
        if let f = fixedMin { lo = f }
        if let f = fixedMax { hi = f }
        if hi <= lo { hi = lo + (lo == 0 ? 1 : abs(lo) * 0.1) }
        let step = nearestNiceStep((hi - lo) / Double(max(1, targetTicks)))
        var nlo = fixedMin ?? (floor(lo / step + 1e-9) * step)
        var nhi = fixedMax ?? (ceil(hi / step - 1e-9) * step)
        // Leave headroom so the tallest mark and its label do not touch the frame.
        if fixedMax == nil, hi > 0, nhi - hi < step * 0.08 { nhi += step }
        if fixedMin == nil, lo < 0, lo - nlo < step * 0.08 { nlo -= step }
        var ticks: [Double] = []
        var t = ceil(nlo / step - 1e-9) * step
        while t <= nhi + step * 1e-6 { ticks.append(abs(t) < step * 1e-9 ? 0 : t); t += step }
        return AxisScale(lower: nlo, upper: nhi, ticks: ticks)
    }

    /// Currency symbol implied by a format string ("$#,0.00", "Currency", "€0").
    static func currencyPrefix(_ format: String) -> String {
        if format.lowercased() == "currency" { return "$" }
        for ch in format { if "$€£¥".contains(ch) { return String(ch) }; if "0#".contains(ch) { break } }
        return ""
    }

    static func isPercent(_ format: String) -> Bool { format.contains("%") || format.lowercased() == "percent" }

    /// Compact label for an axis tick or data label.
    /// - Parameters:
    ///   - units: `.auto` picks K/M/bn per value; `.none` applies the full `format` string.
    ///   - decimals: fixed decimal places; nil trims to at most one (auto units) or follows the format string.
    ///   - format: the measure's format string — keeps currency symbols and percentages.
    public static func label(_ v: Double, units: DisplayUnits = .auto, decimals: Int? = nil, format: String = "") -> String {
        guard v.isFinite else { return "" }
        if isPercent(format) {
            let d = decimals ?? (abs(v) < 0.1 && v != 0 && (v * 100).rounded() != v * 100 ? 1 : 0)
            return trimmed(String(format: "%.\(d)f", v * 100), keep: decimals != nil) + "%"
        }
        if ValueFormatter.isDateLike(format) { return ValueFormatter.format(.double(v), format) }
        let prefix = currencyPrefix(format)
        let sign = v < 0 ? "-" : ""
        let a = abs(v)
        switch units {
        case .none:
            if let decimals { return sign + prefix + grouped(a, decimals) }
            if format.isEmpty || prefix.isEmpty && !format.contains("0") { return ValueFormatter.format(.double(v), "") }
            return ValueFormatter.format(.double(v), format)
        case .auto:
            if let decimals, a < 1000 { return sign + prefix + grouped(a, decimals) }
            return sign + prefix + ValueFormatter.compact(a, decimals: decimals ?? 1)
        default:
            let x = a / units.divisor
            let d = decimals ?? (x == x.rounded() ? 0 : (x < 10 ? 2 : 1))
            return sign + prefix + trimmed(grouped(x, d), keep: decimals != nil) + units.suffix
        }
    }

    private static func grouped(_ v: Double, _ decimals: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = decimals; f.maximumFractionDigits = decimals
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
    private static func trimmed(_ s: String, keep: Bool) -> String {
        guard !keep, s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    /// Tick dates and labels for a continuous date axis, choosing year / quarter / month / week / day / hour
    /// steps so that about `targetCount` labels appear.
    public static func dateTicks(min: Date, max: Date, targetCount: Int) -> [(date: Date, label: String)] {
        let cal = Calendar.utc
        let span = max.timeIntervalSince(min)
        guard span > 0 else { return [(min, ValueFormatter.formatDate(min, ""))] }
        let n = Double(Swift.max(2, targetCount))
        let day = 86400.0
        let comp: Calendar.Component, step: Int, fmt: String
        let approx = span / n
        if approx >= 300 * day { comp = .year; step = Swift.max(1, Int(niceStep(approx / (365.25 * day)).rounded())); fmt = "yyyy" }
        else if approx >= 75 * day { comp = .month; step = approx >= 150 * day ? 6 : 3; fmt = "MMM yyyy" }
        else if approx >= 24 * day { comp = .month; step = approx >= 45 * day ? 2 : 1; fmt = span > 300 * day ? "MMM yyyy" : "MMM" }
        else if approx >= 5 * day { comp = .day; step = approx >= 10 * day ? 14 : 7; fmt = "d MMM" }
        else if approx >= 0.75 * day { comp = .day; step = Swift.max(1, Int((approx / day).rounded())); fmt = "d MMM" }
        else if approx >= 3000 { comp = .hour; step = Swift.max(1, Int((approx / 3600).rounded())); fmt = span > day ? "d MMM HH:mm" : "HH:mm" }
        else { comp = .minute; step = Swift.max(1, Int((approx / 60).rounded())); fmt = "HH:mm" }
        // Align the first tick to a unit boundary.
        var parts: Set<Calendar.Component> = [.year]
        if comp != .year { parts.insert(.month) }
        if comp == .day || comp == .hour || comp == .minute { parts.insert(.day) }
        if comp == .hour || comp == .minute { parts.insert(.hour) }
        var dc = cal.dateComponents(parts, from: min)
        if comp == .month, let m = dc.month, step > 1 { dc.month = ((m - 1) / step) * step + 1 }
        if comp == .year, let y = dc.year, step > 1 { dc.year = (y / step) * step }
        guard var d = cal.date(from: dc) else { return [] }
        var out: [(Date, String)] = []
        var guardCount = 0
        while d <= max, guardCount < 400 {
            if d >= min { out.append((d, DateParsing.string(d, format: fmt))) }
            guard let next = cal.date(byAdding: comp, value: step, to: d) else { break }
            d = next; guardCount += 1
        }
        return out
    }

    /// How many categories to skip between axis labels so labels of `maxLabelWidth` do not collide.
    public static func labelStride(count: Int, maxLabelWidth: CGFloat, available: CGFloat, gap: CGFloat = 8) -> Int {
        guard count > 0, available > 0 else { return 1 }
        let band = available / CGFloat(count)
        return Swift.max(1, Int(((maxLabelWidth + gap) / Swift.max(band, 0.01)).rounded(.up)))
    }
}

extension ValueFormatter {
    /// True when a format string describes a date/time rather than a number.
    static func isDateLike(_ fmt: String) -> Bool {
        let l = fmt.lowercased()
        if ["general date", "short date", "long date", "medium date", "short time", "long time", "medium time"].contains(l) { return true }
        if l.isEmpty || l.contains("0") || l.contains("#") { return false }
        return l.contains("yy") || l.contains("mm") || l.contains("dd") || l.contains("hh")
    }
}

/// Text measurement for layout decisions made outside SwiftUI (label thinning, legends, word clouds).
public enum ChartText {
    private static var cache: [String: CGSize] = [:]
    private static let lock = NSLock()

    /// Size of `s` set in the system font.
    public static func size(_ s: String, fontSize: CGFloat, weight: NSFont.Weight = .regular) -> CGSize {
        let key = "\(fontSize)|\(weight.rawValue)|\(s)"
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let sz = (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: weight)])
        let out = CGSize(width: ceil(sz.width), height: ceil(sz.height))
        if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = out
        return out
    }

    /// Shortens `s` with an ellipsis so it fits `width`.
    public static func truncated(_ s: String, fontSize: CGFloat, width: CGFloat, weight: NSFont.Weight = .regular) -> String {
        if size(s, fontSize: fontSize, weight: weight).width <= width { return s }
        var t = s
        while t.count > 1 {
            t.removeLast()
            if size(t + "…", fontSize: fontSize, weight: weight).width <= width { return t + "…" }
        }
        return "…"
    }
}
