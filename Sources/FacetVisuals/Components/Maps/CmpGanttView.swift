import SwiftUI
import AppKit
import FacetCore
import FacetDesign

/// Gantt chart: task labels on the left, bars on an adaptive time axis (day / week / month / quarter /
/// year cells with a grouping tier above), progress fill, milestone diamonds, today line, zoom.
struct CmpGanttView: View {
    let env: CmpEnv

    @State private var zoomOverride: Double?
    @State private var hOffset: CGFloat = 0
    @State private var hoverRow: Int?
    @State private var hoverPoint: CGPoint = .zero
    @State private var hoverOnBar = false
    @State private var focusRow: Int?
    @State private var hoveringChart = false
    @FocusState private var focused: Bool
    @State private var showRing = false

    private static let chunkSize = 150

    private struct Metrics {
        var labelW: CGFloat, headerH: CGFloat, rowH: CGFloat, timelineW: CGFloat, viewportW: CGFloat
        var twoTier: Bool, compact: Bool
    }

    var body: some View {
        let model = CmpGanttModel(env: env)
        let theme = env.theme
        if !model.hasFields {
            CmpPlaceholder(systemImage: "chart.bar.doc.horizontal", title: "Gantt chart",
                           message: "Add a task, a start and an end date to draw the schedule.", theme: theme)
        } else if model.tasks.isEmpty {
            CmpPlaceholder(systemImage: "calendar.badge.exclamationmark", title: "No dated tasks",
                           message: "None of the rows has a valid start date.", theme: theme)
        } else {
            GeometryReader { geo in
                let showLegend = env.f.bool("legend", "show", true) && !model.legend.isEmpty && geo.size.height >= 120 && geo.size.width >= 180
                VStack(alignment: .leading, spacing: 0) {
                    if showLegend {
                        CmpMapCategoryLegend(title: model.legendTitle, entries: model.legend.map { ($0.label, Color(hex: $0.colorHex)) }, theme: theme)
                            .padding(.bottom, 6)
                    }
                    chart(model, size: CGSize(width: geo.size.width, height: geo.size.height - (showLegend ? 20 : 0)))
                }
            }
            .focusable(env.isInteractive)
            .focused($focused)
            .focusEffectDisabled()
            .overlay { if focused, showRing { RoundedRectangle(cornerRadius: 4).strokeBorder(theme.accentColor.opacity(0.7), lineWidth: 1.5).padding(-3) } }
            .onKeyPress(.downArrow) { step(1, model); return .handled }
            .onKeyPress(.upArrow) { step(-1, model); return .handled }
            .onKeyPress(.space) { activate(focusRow, model); return .handled }
            .onKeyPress(.return) { activate(focusRow, model); return .handled }
            .onKeyPress(.escape) { focusRow = nil; env.context.onSelect([], false); return .handled }
            .onKeyPress(characters: CharacterSet(charactersIn: "+=-0")) { press in
                switch press.characters { case "+", "=": setZoom(zoom * 1.5); case "-": setZoom(zoom / 1.5); default: setZoom(1) }
                return .handled
            }
            .onChange(of: focused) { _, f in
                showRing = f && CmpMapChromeFocus.arrivedByKeyboard
                if !f { focusRow = nil }
            }
        }
    }

    private var zoom: Double { max(1, min(60, zoomOverride ?? env.f.double("gantt", "zoom", 1))) }

    private func setZoom(_ z: Double) {
        let clamped = max(1, min(60, z))
        withAnimation(Design.Motion.quick) { zoomOverride = clamped }
        env.update { $0.setFmt("gantt", "zoom", clamped == 1 ? nil : .number((clamped * 100).rounded() / 100)) }
    }

    // MARK: Layout

    private func metrics(_ model: CmpGanttModel, size: CGSize) -> Metrics {
        let compact = size.height < 110 || size.width < 220
        var labelW: CGFloat = 0
        if env.f.bool("gantt", "showLabels", true), size.width >= 240 {
            let explicit = env.f.double("gantt", "labelWidth", 0)
            if explicit > 0 { labelW = min(CGFloat(explicit), size.width * 0.6) } else {
                let font = env.nsFont(env.theme.label.size + 1)
                let widest = model.tasks.prefix(400).map { CmpFit.width($0.name, font: font) }.max() ?? 0
                labelW = min(size.width * 0.34, max(64, widest + 18))
            }
        }
        let viewportW = max(10, size.width - labelW)
        let timelineW = viewportW * CGFloat(zoom)
        let axis = CmpGanttAxis(start: model.rangeStart, end: model.rangeEnd, width: timelineW)
        let twoTier = !compact && CmpGanttScale.major(for: axis.unit) != nil
        let headerH: CGFloat = twoTier ? 36 : (size.height < 70 ? 14 : 18)
        let wanted = CGFloat(max(12, env.f.double("gantt", "rowHeight", 28)))
        let avail = max(10, size.height - headerH - 1)
        // Shrink rows (down to 14 pt) before resorting to scrolling.
        let rowH = max(min(14, wanted), min(wanted, avail / CGFloat(model.tasks.count)))
        return Metrics(labelW: labelW, headerH: headerH, rowH: rowH, timelineW: timelineW, viewportW: viewportW, twoTier: twoTier, compact: compact)
    }

    private func chart(_ model: CmpGanttModel, size: CGSize) -> some View {
        let m = metrics(model, size: size)
        let theme = env.theme
        let axis = CmpGanttAxis(start: model.rangeStart, end: model.rangeEnd, width: m.timelineW)
        let chunks = stride(from: 0, to: model.tasks.count, by: CmpGanttView.chunkSize).map { $0..<min($0 + CmpGanttView.chunkSize, model.tasks.count) }
        let gridColor = theme.isHighContrast ? theme.foregroundColor.opacity(0.6) : theme.gridlineColor
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                if m.labelW > 0 {
                    Text(model.taskTitle)
                        .font(env.font(theme.label.size, .medium)).foregroundStyle(theme.secondaryColor).lineLimit(1)
                        .padding(.trailing, 8)
                        .frame(width: m.labelW, height: m.twoTier ? m.headerH / 2 : m.headerH, alignment: .leading)
                        .frame(height: m.headerH, alignment: .bottom)
                }
                header(axis, m).frame(width: m.viewportW, height: m.headerH).clipped()
            }
            Rectangle().fill(gridColor).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        if m.labelW > 0 { labels(model, m) }
                        ScrollView(.horizontal) {
                            LazyVStack(spacing: 0) {
                                ForEach(chunks, id: \.lowerBound) { range in
                                    rowsCanvas(model, range: range, axis: axis, m: m)
                                }
                            }
                            .frame(width: m.timelineW)
                            .overlay(alignment: .topLeading) { tooltipOverlay(model, m) }
                        }
                        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in hOffset = x }
                        .frame(width: m.viewportW)
                    }
                }
                .onChange(of: focusRow) { _, r in if let r { withAnimation(Design.Motion.quick) { proxy.scrollTo("label-\(r)") } } }
            }
        }
        .onHover { hoveringChart = $0 }
        .overlay(alignment: .bottomTrailing) {
            if env.isInteractive, !m.compact, hoveringChart || zoom > 1 {
                CmpMapToolbar(theme: theme) {
                    CmpMapToolButton(systemImage: "minus", help: "Zoom out (−)", theme: theme) { setZoom(zoom / 1.5) }
                    CmpMapToolButton(systemImage: "plus", help: "Zoom in (+)", theme: theme) { setZoom(zoom * 1.5) }
                    CmpMapToolButton(systemImage: "arrow.left.and.right", help: "Fit the whole schedule (0)", theme: theme) { setZoom(1) }
                }
                .padding(6)
                .transition(.opacity)
            }
        }
        .simultaneousGesture(MagnifyGesture().onEnded { v in setZoom(zoom * v.magnification) })
    }

    // MARK: Header

    private func header(_ axis: CmpGanttAxis, _ m: Metrics) -> some View {
        let theme = env.theme
        let unit = axis.unit
        let major = m.twoTier ? CmpGanttScale.major(for: unit) : nil
        let minorTicks = CmpGanttScale.ticks(unit, from: axis.start, to: axis.end)
        let majorTicks = major.map { CmpGanttScale.ticks($0, from: axis.start, to: axis.end) } ?? []
        let labelSize = max(9, theme.label.size - (m.headerH < 16 ? 2 : 0))
        let offset = hOffset
        let strong = theme.isHighContrast ? theme.foregroundColor : theme.gridlineColor
        return Canvas { ctx, size in
            let minorTop: CGFloat = major == nil ? 0 : size.height / 2
            // Major tier: label sticks to the left edge while its period is in view.
            if let major {
                for (i, t) in majorTicks.enumerated() where i < majorTicks.count - 1 {
                    let x0 = axis.x(t) - offset, x1 = axis.x(majorTicks[i + 1]) - offset
                    if x1 < 0 || x0 > size.width { continue }
                    let text = CmpGanttScale.label(major, t, width: x1 - x0, isMajor: true)
                    let tw = CmpFit.width(text, font: .systemFont(ofSize: labelSize, weight: .semibold))
                    let right = min(x1, size.width)
                    let lx = min(max(x0, 0) + 6, right - tw - 6)
                    if right - max(x0, 0) > tw + 10 {
                        ctx.draw(Text(text).font(.system(size: labelSize, weight: .semibold)).foregroundColor(theme.foregroundColor),
                                 at: CGPoint(x: lx, y: minorTop / 2), anchor: .leading)
                    }
                    if x0 > 0 {
                        ctx.fill(Path(CGRect(x: x0.rounded(), y: 3, width: 1, height: size.height - 3)), with: .color(strong))
                    }
                }
            }
            // Minor tier: centred labels, thinned so they never overlap.
            var lastRight = -CGFloat.infinity
            for (i, t) in minorTicks.enumerated() where i < minorTicks.count - 1 {
                let x0 = axis.x(t) - offset, x1 = axis.x(minorTicks[i + 1]) - offset
                if x1 < 0 || x0 > size.width { continue }
                let cell = x1 - x0
                let text = CmpGanttScale.label(unit, t, width: cell)
                let tw = CmpFit.width(text, font: .systemFont(ofSize: labelSize))
                let centred = unit != .week
                let lx = centred ? (x0 + x1) / 2 - tw / 2 : x0 + 5
                if lx >= lastRight + 6, lx >= -tw, lx + tw <= size.width + tw, cell >= 6 {
                    if lx >= 1, lx + tw <= size.width - 1 {
                        ctx.draw(Text(text).font(.system(size: labelSize)).foregroundColor(theme.secondaryColor),
                                 at: CGPoint(x: lx, y: minorTop + (size.height - minorTop) / 2), anchor: .leading)
                    }
                    lastRight = lx + tw
                }
                if major != nil, x0 > 0, cell >= 6 {
                    ctx.fill(Path(CGRect(x: x0.rounded(), y: minorTop + 4, width: 1, height: size.height - minorTop - 4)),
                             with: .color(strong.opacity(theme.isHighContrast ? 0.6 : 0.7)))
                }
            }
            // Today marker.
            if env.f.bool("gantt", "todayLine", true) {
                let x = axis.x(Date()) - offset
                if x >= 0, x <= size.width, Date() >= axis.start, Date() <= axis.end {
                    let c = Color(hex: env.f.string("gantt", "todayColor", theme.bad))
                    ctx.fill(Path(roundedRect: CGRect(x: x - 2.5, y: size.height - 3, width: 5, height: 3), cornerRadius: 1), with: .color(c))
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Labels

    private func labels(_ model: CmpGanttModel, _ m: Metrics) -> some View {
        let theme = env.theme
        let hasSelection = !env.context.selection.isEmpty
        return LazyVStack(spacing: 0) {
            ForEach(model.tasks.indices, id: \.self) { i in
                let task = model.tasks[i]
                let selected = hasSelection && (task.selection.map(env.context.isSelected) ?? false)
                Button { activate(i, model) } label: {
                    Text(task.name)
                        .font(env.font(theme.label.size + (m.rowH < 18 ? 0 : 1), selected ? .medium : .regular))
                        .foregroundStyle(theme.foregroundColor.opacity(task.selection.map(env.context.emphasis) ?? 1))
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.trailing, 10)
                        .frame(width: m.labelW, height: m.rowH, alignment: .leading)
                        .background(rowFill(i, selected: selected))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!env.isInteractive)
                .onHover { inside in if inside { hoverRow = i; hoverOnBar = false } else if hoverRow == i { hoverRow = nil } }
                .help(task.name)
                .id("label-\(i)")
                .accessibilityLabel(task.name)
                .accessibilityValue(accessibilityValue(task))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .frame(width: m.labelW)
    }

    private func rowFill(_ i: Int, selected: Bool) -> Color {
        if selected { return env.selectionFill }
        if focusRow == i { return env.accent.opacity(0.1) }
        if hoverRow == i { return env.subtleFill }
        return .clear
    }

    private func accessibilityValue(_ t: CmpGanttTask) -> String {
        let s = ValueFormatter.formatDate(t.start, "")
        if t.isMilestone { return "Milestone on \(s)" }
        var out = "\(s) to \(ValueFormatter.formatDate(t.end.addingTimeInterval(-1), "d MMM yyyy"))"
        if let p = t.progress { out += ", \(Int((p * 100).rounded()))% complete" }
        return out
    }

    // MARK: Rows

    private func rowsCanvas(_ model: CmpGanttModel, range: Range<Int>, axis: CmpGanttAxis, m: Metrics) -> some View {
        let theme = env.theme, f = env.f
        let unit = axis.unit
        let hasSelection = !env.context.selection.isEmpty
        let showGrid = f.bool("gantt", "gridlines", true)
        let showWeekends = f.bool("gantt", "weekends", true) && unit == .day
        let showProgressLabels = f.bool("gantt", "progressLabels", false) && m.rowH >= 16
        let radius = CGFloat(f.double("gantt", "barRadius", 4))
        let grid = theme.isHighContrast ? theme.foregroundColor.opacity(0.45) : theme.gridlineColor
        let minorTicks = CmpGanttScale.ticks(unit, from: axis.start, to: axis.end)
        let majorTicks = CmpGanttScale.major(for: unit).map { CmpGanttScale.ticks($0, from: axis.start, to: axis.end) } ?? []
        let barH = max(6, min(m.rowH - 6, (m.rowH * 0.56).rounded()))
        let height = CGFloat(range.count) * m.rowH
        let today = Date()
        return Canvas { ctx, size in
            if showWeekends {
                for t in minorTicks {
                    let wd = Calendar.utc.component(.weekday, from: t)
                    if wd == 1 || wd == 7 {
                        ctx.fill(Path(CGRect(x: axis.x(t), y: 0, width: CGFloat(axis.pixelsPerDay), height: size.height)),
                                 with: .color(theme.foregroundColor.opacity(theme.isDark ? 0.05 : 0.03)))
                    }
                }
            }
            for (k, i) in range.enumerated() {
                let y = CGFloat(k) * m.rowH
                let task = model.tasks[i]
                let selected = hasSelection && (task.selection.map(env.context.isSelected) ?? false)
                let fill = rowFill(i, selected: selected)
                if fill != .clear { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: m.rowH)), with: .color(fill)) }
                if showGrid, m.rowH >= 16 {
                    ctx.fill(Path(CGRect(x: 0, y: y + m.rowH - 0.5, width: size.width, height: 0.5)), with: .color(grid.opacity(0.7)))
                }
            }
            if showGrid {
                let cell = minorTicks.count > 1 ? axis.x(minorTicks[1]) - axis.x(minorTicks[0]) : 0
                if cell >= 6 {
                    for t in minorTicks.dropFirst() {
                        ctx.fill(Path(CGRect(x: axis.x(t).rounded(), y: 0, width: 0.5, height: size.height)), with: .color(grid.opacity(0.75)))
                    }
                }
                for t in majorTicks.dropFirst() {
                    ctx.fill(Path(CGRect(x: axis.x(t).rounded(), y: 0, width: 1, height: size.height)), with: .color(grid))
                }
            }
            for (k, i) in range.enumerated() {
                let task = model.tasks[i]
                let cy = CGFloat(k) * m.rowH + m.rowH / 2
                let opacity = task.selection.map(env.context.emphasis) ?? (hasSelection ? 0.3 : 1)
                let color = Color(hex: task.colorHex)
                let outline = theme.isHighContrast ? theme.foregroundColor : nil
                if task.isMilestone {
                    let s = barH * 0.62
                    let x = axis.x(task.start)
                    var d = Path()
                    d.move(to: CGPoint(x: x, y: cy - s)); d.addLine(to: CGPoint(x: x + s, y: cy))
                    d.addLine(to: CGPoint(x: x, y: cy + s)); d.addLine(to: CGPoint(x: x - s, y: cy)); d.closeSubpath()
                    let mc = f.value("gantt", "milestoneColor")?.stringValue.map { Color(hex: $0) } ?? color
                    ctx.fill(d, with: .color(mc.opacity(opacity)))
                    ctx.stroke(d, with: .color(outline ?? theme.cardColor), lineWidth: 1)
                    continue
                }
                let x0 = axis.x(task.start)
                let w = max(3, axis.x(task.end) - x0)
                let rect = CGRect(x: x0, y: cy - barH / 2, width: w, height: barH)
                let r = min(radius, barH / 2, w / 2)
                let bar = Path(roundedRect: rect, cornerRadius: r, style: .continuous)
                if let p = task.progress {
                    ctx.fill(bar, with: .color(color.opacity(0.3 * opacity)))
                    if p > 0 {
                        var inner = ctx
                        inner.clip(to: bar)
                        inner.fill(Path(CGRect(x: x0, y: rect.minY, width: w * CGFloat(p), height: barH)), with: .color(color.opacity(opacity)))
                    }
                    if showProgressLabels {
                        let text = Text("\(Int((p * 100).rounded()))%").font(.system(size: max(9, theme.label.size - 1))).foregroundColor(theme.secondaryColor.opacity(opacity))
                        if rect.maxX + 34 < size.width { ctx.draw(text, at: CGPoint(x: rect.maxX + 5, y: cy), anchor: .leading) }
                    }
                } else {
                    ctx.fill(bar, with: .color(color.opacity(0.92 * opacity)))
                }
                if let outline { ctx.stroke(bar, with: .color(outline), lineWidth: 1) }
                if hasSelection, task.selection.map(env.context.isSelected) == true, !theme.isHighContrast {
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: r + 1.5, style: .continuous),
                               with: .color(theme.accentColor), lineWidth: 1.5)
                }
            }
            if f.bool("gantt", "todayLine", true), today >= axis.start, today <= axis.end {
                ctx.fill(Path(CGRect(x: axis.x(today) - 0.5, y: 0, width: 1, height: size.height)),
                         with: .color(Color(hex: f.string("gantt", "todayColor", theme.bad)).opacity(0.85)))
            }
        }
        .frame(width: m.timelineW, height: height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard env.isInteractive else { return }
            switch phase {
            case .active(let p):
                let i = range.lowerBound + min(range.count - 1, max(0, Int(p.y / m.rowH)))
                let task = model.tasks[i]
                hoverRow = i
                hoverPoint = CGPoint(x: p.x, y: CGFloat(range.lowerBound) * m.rowH + p.y)
                let x0 = axis.x(task.start), x1 = task.isMilestone ? x0 : max(x0 + 3, axis.x(task.end))
                hoverOnBar = p.x >= x0 - (task.isMilestone ? barH : 4) && p.x <= x1 + (task.isMilestone ? barH : 4)
            case .ended:
                if let h = hoverRow, range.contains(h) { hoverRow = nil; hoverOnBar = false }
            }
        }
        .gesture(SpatialTapGesture().onEnded { tap in
            guard env.isInteractive else { return }
            focused = true
            let i = range.lowerBound + min(range.count - 1, max(0, Int(tap.location.y / m.rowH)))
            let task = model.tasks[i]
            let x0 = axis.x(task.start), x1 = task.isMilestone ? x0 : max(x0 + 3, axis.x(task.end))
            let pad: CGFloat = task.isMilestone ? barH : 4
            activate(tap.location.x >= x0 - pad && tap.location.x <= x1 + pad ? i : nil, model)
        })
        .accessibilityHidden(m.labelW > 0)
        .accessibilityChildren {
            if m.labelW == 0 {
                ForEach(Array(range), id: \.self) { i in
                    Button(model.tasks[i].name) { activate(i, model) }.accessibilityValue(accessibilityValue(model.tasks[i]))
                }
            }
        }
    }

    @ViewBuilder private func tooltipOverlay(_ model: CmpGanttModel, _ m: Metrics) -> some View {
        if env.f.bool("tooltips", "show", true), hoverOnBar, let i = hoverRow, let task = model.tasks[safe: i] {
            let visible = CGRect(x: hOffset, y: 0, width: m.viewportW, height: max(CGFloat(model.tasks.count) * m.rowH, 80))
            let origin = CmpMapTooltip.origin(for: task.tooltip, near: hoverPoint, in: visible)
            CmpMapTooltip(content: task.tooltip, theme: env.theme).offset(x: origin.x, y: origin.y)
        }
    }

    // MARK: Interaction

    private func activate(_ index: Int?, _ model: CmpGanttModel) {
        let additive = NSEvent.modifierFlags.contains(.command)
        guard let index, let point = model.tasks[safe: index]?.selection else {
            if !additive { env.context.onSelect([], false) }
            return
        }
        env.context.onSelect([point], additive)
    }

    private func step(_ delta: Int, _ model: CmpGanttModel) {
        showRing = true
        let n = model.tasks.count
        guard n > 0 else { return }
        focusRow = focusRow.map { max(0, min(n - 1, $0 + delta)) } ?? (delta > 0 ? 0 : n - 1)
    }
}
