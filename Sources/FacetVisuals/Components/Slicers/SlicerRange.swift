import SwiftUI
import FacetCore
import FacetDesign

// Range slicers (between / before / after, numeric or date) and relative date / time slicers.

/// Text field for a number that commits on Return or when focus leaves.
struct CmpSlNumberField: View {
    let value: Double?
    let placeholder: String
    let display: (Double) -> String
    let env: CmpEnv
    let cfg: CmpSlConfig
    let label: String
    var alignment: TextAlignment = .leading
    let commit: (Double?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(env.secondary))
            .textFieldStyle(.plain)
            .font(env.font(cfg.fontSize).monospacedDigit())
            .foregroundStyle(cfg.text)
            .multilineTextAlignment(alignment)
            .focused($focused)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(CmpSlFieldBackground(env: env, focused: focused))
            .onSubmit(push)
            .onChange(of: focused) { _, now in if !now { push() } }
            .onChange(of: value) { _, v in if !focused { text = v.map(display) ?? "" } }
            .onAppear { text = value.map(display) ?? "" }
            .accessibilityLabel(label)
            .help(label)
    }

    private func push() {
        let t = text.trimmingCharacters(in: .whitespaces)
        let parsed = t.isEmpty ? nil : DataTable.parseNumber(t)
        if !t.isEmpty, parsed == nil { text = value.map(display) ?? ""; return }
        if parsed != value { commit(parsed) }
        text = parsed.map(display) ?? ""
    }
}

/// Date field: type a date (any common format) or pick one from the calendar popover.
struct CmpSlDateField: View {
    /// Seconds since 1970; nil = bound not set (shows the data bound as a placeholder).
    let value: Double?
    let fallback: Double
    let display: (Double) -> String
    let env: CmpEnv
    let cfg: CmpSlConfig
    let label: String
    var showCalendar = true
    let commit: (Double) -> Void
    @State private var text = ""
    @State private var open = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text, prompt: Text(display(fallback)).foregroundColor(env.secondary))
                .textFieldStyle(.plain)
                .font(env.font(cfg.fontSize).monospacedDigit())
                .foregroundStyle(cfg.text)
                .focused($focused)
                .onSubmit(push)
                .onChange(of: focused) { _, now in if !now { push() } }
                .onChange(of: value) { _, v in if !focused { text = v.map(display) ?? "" } }
                .onAppear { text = value.map(display) ?? "" }
                .accessibilityLabel(label)
            if showCalendar {
            Button { open.toggle() } label: {
                Image(systemName: "calendar").font(.system(size: 11)).foregroundStyle(env.secondary)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose \(label.lowercased())")
            .accessibilityLabel("Choose \(label.lowercased()) from calendar")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                DatePicker("", selection: Binding(get: { Date(timeIntervalSince1970: value ?? fallback) },
                                                  set: { commit($0.timeIntervalSince1970) }),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .current)
                    .environment(\.calendar, .utc)
                    .padding(10)
            }
            }
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 5)
        .background(CmpSlFieldBackground(env: env, focused: focused))
        .help(label)
    }

    private func push() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let d = DateParsing.parse(t) else { text = value.map(display) ?? ""; return }
        let ti = d.timeIntervalSince1970
        if ti != value { commit(ti) }
        text = display(ti)
    }
}

/// One- or two-thumb slider. Dragging reports live values; `onEnd` commits.
struct CmpSlRangeSlider: View {
    enum Thumb: Hashable { case low, high }
    let low: Double
    let high: Double
    let showLow: Bool
    let showHigh: Bool
    let bounds: (min: Double, max: Double)
    let step: Double
    let env: CmpEnv
    let cfg: CmpSlConfig
    let describe: (Double) -> String
    let onChange: (_ low: Double, _ high: Double) -> Void
    let onEnd: () -> Void
    @FocusState private var focus: Thumb?
    @State private var ring: Thumb?
    private let r: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - r * 2)
            let span = max(bounds.max - bounds.min, .leastNonzeroMagnitude)
            let xl = r + CGFloat((min(max(low, bounds.min), bounds.max) - bounds.min) / span) * w
            let xh = r + CGFloat((min(max(high, bounds.min), bounds.max) - bounds.min) / span) * w
            let from = showLow ? xl : r, to = showHigh ? xh : r + w
            ZStack(alignment: .leading) {
                Capsule().fill(env.grid).frame(height: 4).padding(.horizontal, r - 2)
                Capsule().fill(cfg.selected).frame(width: max(0, to - from), height: 4).offset(x: from)
                if showLow { thumb(.low, x: xl, w: w, span: span) }
                if showHigh { thumb(.high, x: xh, w: w, span: span) }
            }
            .frame(height: geo.size.height)
            .coordinateSpace(name: "cmpSlTrack")
        }
        .frame(height: 20)
    }

    private func thumb(_ which: Thumb, x: CGFloat, w: CGFloat, span: Double) -> some View {
        let value = which == .low ? low : high
        return Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
            .overlay { if ring == which, focus == which { Circle().strokeBorder(cfg.selected, lineWidth: 2).padding(-3) } }
            .frame(width: r * 2, height: r * 2)
            .offset(x: x - r)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cmpSlTrack"))
                .onChanged { g in
                    let v = bounds.min + Double(min(max(g.location.x - r, 0), w) / w) * span
                    set(which, v)
                }
                .onEnded { _ in onEnd() })
            .focusable(env.isInteractive)
            .focused($focus, equals: which)
            .focusEffectDisabled()
            .onChange(of: focus) { _, new in ring = CmpSlFocus.viaKeyboard ? new : nil }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .downArrow, .upArrow], phases: [.down, .repeat]) { press in
                ring = which
                let up = press.key == .rightArrow || press.key == .upArrow
                set(which, value + (up ? step : -step) * (press.modifiers.contains(.shift) ? 10 : 1))
                onEnd()
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel(which == .low ? "Lower bound" : "Upper bound")
            .accessibilityValue(describe(value))
            .accessibilityAdjustableAction { dir in
                set(which, value + (dir == .increment ? step : -step))
                onEnd()
            }
            .help(describe(value))
    }

    private func set(_ which: Thumb, _ raw: Double) {
        let v = min(max(raw, bounds.min), bounds.max)
        if which == .low { onChange(showHigh ? min(v, high) : v, high) } else { onChange(low, showLow ? max(v, low) : v) }
    }
}

/// Between / before / after. Writes `rangeLow` and/or `rangeHigh` (numbers or dates; unset bound = `.null`).
struct CmpSlRangeView: View {
    let session: CmpSlSession
    let column: Int
    /// "between" | "before" | "after"
    let mode: String
    let size: CGSize
    @State private var live: (low: Double, high: Double)?

    var body: some View {
        let env = session.env, cfg = session.cfg, data = env.data
        let isDate = CmpSlLogic.isDateColumn(data, column: column)
        let now = Date().timeIntervalSince1970
        let ext = CmpSlLogic.extent(data, column: column, isDate: isDate) ?? (isDate ? (now - 365 * 86400, now) : (0, 100))
        let bounds = ext.max > ext.min ? ext : (ext.min, ext.min + (isDate ? 86400 : 1))
        let stateLow = number(session.state.rangeLow, isDate), stateHigh = number(session.state.rangeHigh, isDate)
        let low = live?.low ?? stateLow ?? bounds.0, high = live?.high ?? stateHigh ?? bounds.1
        let showLow = mode != "before", showHigh = mode != "after"
        let describe: (Double) -> String = { format($0, isDate) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if mode != "between", size.width >= 170 {
                    Text(mode == "before" ? (isDate ? "On or before" : "At most") : (isDate ? "On or after" : "At least"))
                        .font(env.font(cfg.fontSize)).foregroundStyle(env.secondary).lineLimit(1).fixedSize()
                }
                if showLow {
                    field(isLow: true, value: live?.low ?? stateLow, fallback: bounds.0, bounds: bounds, isDate: isDate, describe: describe)
                }
                if mode == "between" {
                    Rectangle().fill(env.secondary.opacity(0.6)).frame(width: 6, height: 1)
                }
                if showHigh {
                    field(isLow: false, value: live?.high ?? stateHigh, fallback: bounds.1, bounds: bounds, isDate: isDate, describe: describe)
                }
            }
            if cfg.showSlider, size.height >= 58 {
                CmpSlRangeSlider(low: low, high: high, showLow: showLow, showHigh: showHigh, bounds: bounds,
                                 step: step(bounds, isDate), env: env, cfg: cfg, describe: describe,
                                 onChange: { l, h in live = (snap(l, bounds, isDate), snap(h, bounds, isDate)) },
                                 onEnd: { if let v = live { commit(showLow ? v.low : nil, showHigh ? v.high : nil, isDate); live = nil } })
                if size.height >= 78 {
                    HStack {
                        Text(describe(bounds.0))
                        Spacer(minLength: 4)
                        Text(describe(bounds.1))
                    }
                    .font(env.font(max(9, cfg.fontSize - 2)).monospacedDigit())
                    .foregroundStyle(env.secondary)
                    .lineLimit(1)
                    .padding(.top, -6)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private func field(isLow: Bool, value: Double?, fallback: Double, bounds: (Double, Double), isDate: Bool,
                       describe: @escaping (Double) -> String) -> some View {
        let env = session.env, cfg = session.cfg
        let label = isLow ? (isDate ? "Start date" : "Minimum") : (isDate ? "End date" : "Maximum")
        if isDate {
            CmpSlDateField(value: value, fallback: fallback, display: describe, env: env, cfg: cfg, label: label,
                           showCalendar: size.width >= (mode == "between" ? 230 : 170)) { t in
                let v = snap(t, bounds, true)
                let lo = isLow ? v : number(session.state.rangeLow, true)
                let hi = isLow ? number(session.state.rangeHigh, true) : v
                commit(mode == "before" ? nil : lo, mode == "after" ? nil : hi, true)
            }
            .frame(maxWidth: .infinity)
        } else {
            CmpSlNumberField(value: value, placeholder: describe(fallback), display: describe, env: env, cfg: cfg, label: label) { v in
                let lo = isLow ? v : number(session.state.rangeLow, false)
                let hi = isLow ? number(session.state.rangeHigh, false) : v
                commit(mode == "before" ? nil : lo, mode == "after" ? nil : hi, false)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func number(_ v: Value, _ isDate: Bool) -> Double? {
        if v.isNull { return nil }
        return isDate ? v.asDate?.timeIntervalSince1970 : v.asDouble
    }
    private var isInteger: Bool {
        let t = session.env.data.table.columns[safe: column]?.type
        return t == .integer
    }
    private func value(_ d: Double, _ isDate: Bool) -> Value {
        if isDate { return .date(Date(timeIntervalSince1970: d)) }
        return isInteger ? .int(Int64(d.rounded())) : .double(d)
    }
    private func step(_ b: (Double, Double), _ isDate: Bool) -> Double {
        if isDate { return 86400 }
        if isInteger { return max(1, ((b.1 - b.0) / 100).rounded()) }
        return (b.1 - b.0) / 100
    }
    private func snap(_ d: Double, _ b: (Double, Double), _ isDate: Bool) -> Double {
        if isDate { return (d / 86400).rounded() * 86400 }
        if isInteger { return d.rounded() }
        let span = b.1 - b.0
        let unit = pow(10, floor(log10(max(span, 1e-9))) - 2)
        return min(b.1, max(b.0, (d / unit).rounded() * unit))
    }
    private func format(_ d: Double, _ isDate: Bool) -> String {
        let fmt = session.env.data.formats[safe: column] ?? ""
        if isDate { return ValueFormatter.format(.date(Date(timeIntervalSince1970: d)), fmt) }
        return ValueFormatter.format(isInteger ? .int(Int64(d.rounded())) : .double(d), fmt)
    }
    private func commit(_ low: Double?, _ high: Double?, _ isDate: Bool) {
        session.update {
            $0.rangeLow = low.map { value($0, isDate) } ?? .null
            $0.rangeHigh = high.map { value($0, isDate) } ?? .null
        }
    }
}

/// Relative date / time: "Last 7 days", "This calendar month", "Next 2 hours". Writes `SlicerState.relative`.
struct CmpSlRelativeView: View {
    let session: CmpSlSession
    let isTime: Bool
    let size: CGSize

    var body: some View {
        let env = session.env, cfg = session.cfg
        let active = session.state.relative != nil
        let r = session.state.relative ?? defaults
        let units = isTime ? CmpSlRelative.timeUnits : CmpSlRelative.dateUnits
        let direction = CmpSlMenu(title: CmpSlRelative.label(r.direction),
                                  options: RelativeDateFilter.Direction.allCases.map { ($0.rawValue, CmpSlRelative.label($0)) },
                                  env: env, cfg: cfg, accessibility: "Direction") { id in
            set { $0.direction = RelativeDateFilter.Direction(rawValue: id) ?? .last }
        }
        let count = CmpSlNumberField(value: Double(r.count), placeholder: "7", display: { String(Int($0)) }, env: env, cfg: cfg,
                                     label: "Number of periods", alignment: .center) { v in
            set { $0.count = max(1, Int(v ?? 1)) }
        }
        .frame(width: 46)
        let unit = CmpSlMenu(title: CmpSlRelative.label(r.unit, plural: r.direction != .this && r.count != 1),
                             options: units.map { ($0.rawValue, CmpSlRelative.label($0)) },
                             env: env, cfg: cfg, accessibility: "Period") { id in
            set { $0.unit = RelativeDateFilter.Unit(rawValue: id) ?? (isTime ? .hours : .days) }
        }
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { direction; if r.direction != .this { count }; unit }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) { direction; if r.direction != .this { count } }
                    unit
                }
            }
            if !isTime, r.direction != .this, size.height >= 76 {
                CmpSlRow(label: "Include today", check: r.includeToday ? .on : .off, appearance: .check, env: env, cfg: cfg) { _ in
                    set { $0.includeToday.toggle() }
                }
                .padding(.leading, -6)
            }
            if size.height >= 52 {
                HStack(spacing: 5) {
                    Image(systemName: isTime ? "clock" : "calendar").font(.system(size: 10))
                    Text(active ? CmpSlRelative.summary(r) : "No filter applied").lineLimit(1)
                }
                .font(env.font(max(10, cfg.fontSize - 1)))
                .foregroundStyle(env.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(active ? "\(CmpSlRelative.sentence(r)): \(CmpSlRelative.summary(r))" : "No filter applied")
            }
        }
        .opacity(active ? 1 : 0.85)
    }

    private var defaults: RelativeDateFilter {
        var d = RelativeDateFilter()
        if isTime { d.unit = .hours; d.count = 1 }
        return d
    }
    private func set(_ mutate: (inout RelativeDateFilter) -> Void) {
        var r = session.state.relative ?? defaults
        mutate(&r)
        let allowed = isTime ? CmpSlRelative.timeUnits : CmpSlRelative.dateUnits
        if !allowed.contains(r.unit) { r.unit = isTime ? .hours : .days }
        session.update { $0.relative = r }
    }
}
