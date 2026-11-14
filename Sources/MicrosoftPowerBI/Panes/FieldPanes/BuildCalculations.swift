import SwiftUI
import FacetCore
import FacetDesign

// Visual calculations and analytics sections of the Build pane.

// MARK: - Visual calculations

struct VisualCalcTemplateItem: Identifiable {
    var id: String { name }
    var name: String
    /// Expression with `[Field]` standing for the first value field.
    var pattern: String
    var format = ""

    static let all: [VisualCalcTemplateItem] = [
        .init(name: "Running sum", pattern: "RUNNINGSUM([Field])"),
        .init(name: "Moving average", pattern: "MOVINGAVERAGE([Field], 3)"),
        .init(name: "Percent of parent", pattern: "DIVIDE([Field], COLLAPSE([Field], ROWS))", format: "0.0%"),
        .init(name: "Percent of grand total", pattern: "DIVIDE([Field], COLLAPSEALL([Field], ROWS))", format: "0.0%"),
        .init(name: "Average of children", pattern: "EXPAND(AVERAGE([Field]), ROWS)"),
        .init(name: "Versus previous", pattern: "[Field] - PREVIOUS([Field])"),
        .init(name: "Versus next", pattern: "[Field] - NEXT([Field])"),
        .init(name: "Versus first", pattern: "[Field] - FIRST([Field])"),
        .init(name: "Versus last", pattern: "[Field] - LAST([Field])"),
    ]

    func expression(for caption: String) -> String {
        pattern.replacingOccurrences(of: "[Field]", with: "[\(caption.replacingOccurrences(of: "]", with: "]]"))]")
    }
}

extension VisualSpec {
    /// Caption of the first value field — what calculation templates operate on.
    var firstValueCaption: String? {
        type.wells.filter { !$0.isGrouping && $0 != .tooltips }.flatMap { fields($0) }.first(where: \.isAggregate)?.caption
            ?? allFields.first(where: \.isAggregate)?.caption
    }
}

struct VisualCalculationsSection: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec

    var body: some View {
        FieldPaneSection("Visual calculations", count: spec.visualCalculations.count, expanded: !spec.visualCalculations.isEmpty) {
            Menu {
                Button("Blank calculation") { edit(nil, template: nil) }
                Divider()
                ForEach(VisualCalcTemplateItem.all) { t in Button(t.name) { edit(nil, template: t) } }
            } label: { Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("New visual calculation").accessibilityLabel("New visual calculation")
        } content: {
            if spec.visualCalculations.isEmpty {
                PaneHint("Calculations over this visual's own rows — running totals, moving averages, percent of parent.")
            } else {
                VStack(spacing: 2) {
                    ForEach(spec.visualCalculations) { c in CalcRow(spec: spec, calc: c) { edit(c, template: nil) } }
                }
            }
        }
    }

    private func edit(_ calc: VisualCalculation?, template: VisualCalcTemplateItem?) {
        var draft = calc ?? VisualCalculation(name: "", expression: "")
        if calc == nil {
            let existing = Set(spec.visualCalculations.map(\.name) + spec.allFields.map(\.caption))
            let base = template?.name ?? "Calculation"
            var name = base, n = 2
            while existing.contains(name) { name = "\(base) \(n)"; n += 1 }
            draft.name = name
            if let template {
                draft.expression = template.expression(for: spec.firstValueCaption ?? "Field")
                draft.formatString = template.format
            }
        }
        let id = spec.id, isNew = calc == nil
        store.present { VisualCalculationEditor(visualID: id, isNew: isNew, calc: draft) }
    }
}

private struct CalcRow: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    let calc: VisualCalculation
    let edit: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: "function").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            Text(calc.name).font(Design.Typeface.body).lineLimit(1).foregroundStyle(calc.isHidden ? .secondary : .primary)
            if calc.isHidden { Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.tertiary).help("Hidden") }
            Spacer(minLength: 0)
            MiniIconButton("pencil", help: "Edit \(calc.name)", action: edit)
            MiniIconButton("xmark", help: "Delete \(calc.name)") {
                store.updateVisual(spec.id, name: "Delete Visual Calculation") { v in v.visualCalculations.removeAll { $0.id == calc.id } }
            }
        }
        .padding(.leading, Design.Space.s).padding(.trailing, 2)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(hovering ? Design.Palette.fillStrong : Design.Palette.fill))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: edit)
        .help(calc.expression)
    }
}

/// Sheet for writing a visual calculation.
struct VisualCalculationEditor: View {
    @EnvironmentObject var store: DocumentStore
    let visualID: UUID
    let isNew: Bool
    @State var calc: VisualCalculation
    @State private var issues: [ExpressionIssue] = []
    @State private var checking = false

    private var spec: VisualSpec? { store.visual(visualID) }
    private var nameProblem: String? {
        let n = calc.name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "Give the calculation a name." }
        guard let spec else { return nil }
        if spec.visualCalculations.contains(where: { $0.id != calc.id && $0.name.caseInsensitiveCompare(n) == .orderedSame })
            || spec.allFields.contains(where: { $0.caption.caseInsensitiveCompare(n) == .orderedSame }) {
            return "“\(n)” is already used in this visual."
        }
        return nil
    }
    private var errors: [ExpressionIssue] { issues.filter { !$0.isWarning } }
    private var canSave: Bool {
        nameProblem == nil && !calc.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && errors.isEmpty && !checking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            HStack {
                Text(isNew ? "New visual calculation" : "Edit visual calculation").font(Design.Typeface.headline)
                Spacer()
                Menu("Templates") {
                    ForEach(VisualCalcTemplateItem.all) { t in
                        Button(t.name) {
                            calc.expression = t.expression(for: spec?.firstValueCaption ?? "Field")
                            if calc.formatString.isEmpty { calc.formatString = t.format }
                        }
                    }
                }
                .controlSize(.small).fixedSize()
                .help("Insert a template using the visual's first value field")
            }
            PropertyRow("Name") {
                TextField("Name", text: $calc.name).textFieldStyle(.roundedBorder).controlSize(.small)
            }
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                SectionLabel("Expression")
                CodeEditor(text: $calc.expression, language: LanguageSupport.dax, model: store.model, issues: issues,
                           onCommit: { if canSave { save() } }, onCancel: { store.dismissSheet() })
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(Design.Palette.elevated))
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).strokeBorder(Design.Palette.hairlineStrong))
                if let spec, !spec.allFields.isEmpty {
                    Text("Refer to this visual's fields by caption: " + spec.allFields.prefix(4).map { "[\($0.caption)]" }.joined(separator: ", "))
                        .font(Design.Typeface.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
                ForEach(issues) { issue in
                    Label(issue.message, systemImage: issue.isWarning ? "exclamationmark.triangle" : "xmark.octagon")
                        .font(Design.Typeface.caption)
                        .foregroundStyle(issue.isWarning ? Design.Palette.caution : Design.Palette.negative)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            PropertyRow("Format") {
                HStack(spacing: Design.Space.xs) {
                    TextField("Automatic", text: $calc.formatString).textFieldStyle(.roundedBorder).controlSize(.small).font(Design.Typeface.mono)
                    Menu {
                        Button("Automatic") { calc.formatString = "" }
                        Divider()
                        ForEach(["#,0", "#,0.00", "0%", "0.0%", "$#,0", "$#,0.00"], id: \.self) { f in
                            Button("\(f)   \(ValueFormatter.format(.double(f.contains("%") ? 0.1234 : 12345.678), f))") { calc.formatString = f }
                        }
                    } label: { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Common formats").accessibilityLabel("Common formats")
                }
            }
            Toggle("Hide in the visual (still usable by other calculations)", isOn: $calc.isHidden)
                .toggleStyle(.checkbox).controlSize(.small)
            HStack {
                if let p = nameProblem { Text(p).font(Design.Typeface.caption).foregroundStyle(Design.Palette.caution) }
                Spacer()
                Button("Cancel", role: .cancel) { store.dismissSheet() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }.keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(Design.Space.l)
        .frame(width: 520)
        .task(id: calc.expression) {
            let expr = calc.expression
            guard !expr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { issues = []; return }
            checking = true
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let found = await store.withEngine { $0.check(expr, kind: .visualCalculation, homeTable: nil) }
            if Task.isCancelled { return }
            issues = found
            checking = false
        }
    }

    private func save() {
        var c = calc
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        c.formatString = c.formatString.trimmingCharacters(in: .whitespaces)
        store.updateVisual(visualID, name: isNew ? "Add Visual Calculation" : "Edit Visual Calculation") { v in
            if let i = v.visualCalculations.firstIndex(where: { $0.id == c.id }) { v.visualCalculations[i] = c }
            else { v.visualCalculations.append(c) }
        }
        store.dismissSheet()
    }
}

// MARK: - Analytics

struct AnalyticsSection: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec

    var body: some View {
        let kinds = BuildLogic.analyticsKinds(for: spec, model: store.model)
        let available = kinds.filter { k in !BuildLogic.isSingleton(k) || !spec.analytics.contains { $0.kind == k } }
        FieldPaneSection("Analytics", count: spec.analytics.count, expanded: !spec.analytics.isEmpty) {
            if !available.isEmpty {
                Menu {
                    ForEach(available, id: \.self) { k in
                        Button { add(k) } label: { Label(BuildLogic.title(k), systemImage: BuildLogic.symbol(k)) }
                    }
                } label: { Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Add a line, forecast or other analysis").accessibilityLabel("Add analytics")
            }
        } content: {
            if spec.analytics.isEmpty {
                PaneHint("Add reference lines, trends and forecasts to this chart.")
            } else {
                ForEach(spec.analytics) { item in AnalyticsItemEditor(spec: spec, item: item) }
            }
        }
    }

    private func add(_ kind: AnalyticsItem.Kind) {
        let item = BuildLogic.newItem(kind)
        store.updateVisual(spec.id, name: "Add \(BuildLogic.title(kind))") { $0.analytics.append(item) }
    }
}

private struct AnalyticsItemEditor: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    let item: AnalyticsItem
    @State private var expanded = true

    private func edit(_ change: @escaping (inout AnalyticsItem) -> Void) {
        store.updateVisual(spec.id, name: "Change \(BuildLogic.title(item.kind))", coalesce: "analytics-\(item.id)") { v in
            if let i = v.analytics.firstIndex(where: { $0.id == item.id }) { change(&v.analytics[i]) }
        }
    }

    private var isReferenceLine: Bool {
        switch item.kind { case .constantLine, .minLine, .maxLine, .averageLine, .medianLine, .percentileLine: return true; default: return false }
    }
    private var hasLineStyle: Bool { isReferenceLine || item.kind == .trendLine || item.kind == .ratioLine }
    private var hasSeries: Bool {
        switch item.kind { case .symmetryShading, .ratioLine, .clusters: return false; default: return spec.type != .scatter }
    }
    private var seriesFields: [FieldRef] {
        var seen = Set<String>()
        return spec.type.wells.filter { !$0.isGrouping && $0 != .tooltips }.flatMap { spec.fields($0) }
            .filter { $0.isAggregate && seen.insert($0.key).inserted }
    }
    private var lineStyle: String {
        let s = item.style.lowercased()
        return s.hasPrefix("solid") ? "solid" : (s.hasPrefix("dotted") ? "dotted" : "dashed")
    }
    private var shade: String {
        let s = item.style.lowercased()
        return s.contains("shadeabove") ? "shadeabove" : (s.contains("shadebelow") ? "shadebelow" : "")
    }
    private func compose(line: String, shade: String) -> String { shade.isEmpty ? line : "\(line) \(shade)" }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: Design.Space.xs) {
                Button { withAnimation(Design.Motion.quick) { expanded.toggle() } } label: {
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.tertiary).frame(width: 10)
                        Image(systemName: BuildLogic.symbol(item.kind)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                        Text(item.name.isEmpty ? BuildLogic.title(item.kind) : item.name).font(Design.Typeface.body).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                MiniIconButton("xmark", help: "Remove \(BuildLogic.title(item.kind).lowercased())") {
                    store.updateVisual(spec.id, name: "Remove \(BuildLogic.title(item.kind))") { v in v.analytics.removeAll { $0.id == item.id } }
                }
            }
            .frame(height: 26)
            if expanded {
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    if isReferenceLine {
                        PropertyRow("Name") { CommitTextField(BuildLogic.title(item.kind), text: item.name) { n in edit { $0.name = n } } }
                    }
                    parameters
                    if hasSeries, seriesFields.count > 1 {
                        PropertyRow("Series") {
                            Picker("Series", selection: Binding(get: { item.seriesKey ?? "" }, set: { k in edit { $0.seriesKey = k.isEmpty ? nil : k } })) {
                                Text("All").tag("")
                                Divider()
                                ForEach(seriesFields) { f in Text(f.caption).tag(f.key) }
                            }
                            .labelsHidden().controlSize(.small)
                        }
                    }
                    PropertyRow("Colour") {
                        HStack(spacing: Design.Space.s) {
                            CommitColorWell(hex: item.color ?? store.theme.secondaryForeground) { h in edit { $0.color = h } }
                            if item.color != nil {
                                Button("Automatic") { edit { $0.color = nil } }.buttonStyle(.link).controlSize(.small)
                            } else {
                                Text("Automatic").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if hasLineStyle {
                        PropertyRow("Line") {
                            Picker("Line style", selection: Binding(get: { lineStyle }, set: { s in let sh = shade; edit { $0.style = compose(line: s, shade: sh) } })) {
                                Text("Dashed").tag("dashed"); Text("Solid").tag("solid"); Text("Dotted").tag("dotted")
                            }
                            .labelsHidden().controlSize(.small)
                        }
                    }
                    if isReferenceLine {
                        PropertyRow("Shade") {
                            Picker("Shade", selection: Binding(get: { shade }, set: { s in let l = lineStyle; edit { $0.style = compose(line: l, shade: s) } })) {
                                Text("None").tag(""); Text("Above the line").tag("shadeabove"); Text("Below the line").tag("shadebelow")
                            }
                            .labelsHidden().controlSize(.small)
                        }
                        Toggle("Show label", isOn: Binding(get: { item.showLabel }, set: { on in edit { $0.showLabel = on } }))
                            .toggleStyle(.checkbox).controlSize(.small)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    @ViewBuilder
    private var parameters: some View {
        switch item.kind {
        case .constantLine:
            PropertyRow("Value") { CommitNumberField(value: item.value, width: 90) { v in edit { $0.value = v } } }
        case .percentileLine:
            PropertyRow("Percentile") { CommitNumberField(value: item.value, range: 0...100) { v in edit { $0.value = v } } }
        case .forecast:
            PropertyRow("Length") {
                HStack(spacing: Design.Space.xs) {
                    CommitNumberField(value: item.value, range: 1...Double(AnalyticsSeries.maxForecastLength)) { v in edit { $0.value = v.rounded() } }
                    Text("points").font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
            }
            PropertyRow("Ignore the last") {
                HStack(spacing: Design.Space.xs) {
                    CommitNumberField(value: Double(item.ignoreLast ?? 0), range: 0...Double(AnalyticsSeries.maxForecastLength)) { v in
                        edit { $0.ignoreLast = v >= 1 ? Int(v.rounded()) : nil }
                    }
                    Text("points").font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
            }
            PropertyRow("Seasonality") {
                HStack(spacing: Design.Space.xs) {
                    OptionalNumberField(value: item.seasonality.map(Double.init)) { v in
                        edit { $0.seasonality = v.flatMap { $0.isFinite ? Int(min(max($0.rounded(), 1), 1000)) : nil } }
                    }
                    Text(ForecastCard.seasonalityHint(item.seasonality)).font(Design.Typeface.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            PropertyRow("Confidence") {
                Picker("Confidence interval", selection: Binding(get: { item.secondaryValue }, set: { v in edit { $0.secondaryValue = v } })) {
                    ForEach(ForecastCard.confidenceLevels, id: \.self) { c in Text("\(Int(c))%").tag(c) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
            }
        case .errorBars:
            PropertyRow("Error") {
                HStack(spacing: Design.Space.xs) {
                    Text("±").font(Design.Typeface.caption).foregroundStyle(.secondary)
                    CommitNumberField(value: item.secondaryValue, range: 0...1000) { v in edit { $0.secondaryValue = v } }
                    Text("% of value").font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
            }
        case .anomalies:
            PropertyRow("Sensitivity") {
                HStack(spacing: Design.Space.xs) {
                    Slider(value: Binding(get: { item.value }, set: { v in edit { $0.value = v.rounded() } }), in: 1...100).controlSize(.small)
                    Text("\(Int(item.value))%").font(Design.Typeface.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 34, alignment: .trailing)
                }
            }
        case .clusters:
            PropertyRow("Clusters") {
                HStack(spacing: Design.Space.xs) {
                    OptionalNumberField(value: item.secondaryValue >= 2 ? item.secondaryValue : nil) { v in
                        edit { $0.secondaryValue = v.map { min(max($0.rounded(), 2), 20) } ?? 0 }
                    }
                    Text("Leave empty to detect").font(Design.Typeface.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        case .minLine, .maxLine, .averageLine, .medianLine, .trendLine, .symmetryShading, .ratioLine:
            EmptyView()
        }
    }
}
