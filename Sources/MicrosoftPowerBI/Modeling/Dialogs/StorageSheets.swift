import SwiftUI
import FacetCore
import FacetDesign

/// Incremental refresh policy for one table.
struct IncrementalRefreshSheet: View {
    @EnvironmentObject private var store: DocumentStore
    let table: String
    @State private var enabled: Bool
    @State private var policy: IncrementalRefreshPolicy
    @State private var detectChanges: Bool

    init(table: ModelTable) {
        self.table = table.name
        let existing = table.incrementalRefresh
        _enabled = State(initialValue: true)
        _policy = State(initialValue: existing ?? IncrementalRefreshPolicy(
            dateColumn: table.columns.first { ($0.dataType == .date || $0.dataType == .dateTime) && !$0.isCalculated }?.name ?? ""))
        _detectChanges = State(initialValue: existing?.detectChangesColumn != nil)
    }

    private var modelTable: ModelTable { store.model.table(table) ?? ModelTable(name: table) }
    private var effective: IncrementalRefreshPolicy {
        var p = policy
        if !detectChanges { p.detectChangesColumn = nil }
        return IncrementalRefreshLogic.normalized(p)
    }
    private var problems: [String] { enabled ? IncrementalRefreshLogic.problems(effective, table: modelTable) : [] }
    private var missing: [String] { IncrementalRefreshLogic.missingParameters(store.doc.queries) }
    private var sourceQuery: QueryDefinition? {
        let name = modelTable.sourceQuery ?? table
        return store.doc.queries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var body: some View {
        ModelingSheet(title: "Incremental refresh and real-time data",
                      subtitle: "Keep years of history in \(table) but reload only the most recent periods on each refresh. The policy takes effect once the model is published.",
                      width: 620, height: nil) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                Toggle("Incrementally refresh \(table)", isOn: $enabled).toggleStyle(.switch)
                if enabled {
                    ModelField("Partition by") {
                        ModelColumnPicker(label: "Date column", table: table, selection: $policy.dateColumn,
                                          filter: { ($0.dataType == .date || $0.dataType == .dateTime) && !$0.isCalculated }).frame(width: 220)
                    }
                    period("Archive data starting", count: $policy.archiveCount, unit: $policy.archiveUnit, tail: "before the refresh date")
                    period("Refresh data starting", count: $policy.refreshCount, unit: $policy.refreshUnit, tail: "before the refresh date")
                    VStack(alignment: .leading, spacing: Design.Space.xs) {
                        Toggle("Only refresh complete \(IncrementalRefreshLogic.unitTitle(policy.refreshUnit, count: 2))", isOn: Binding(
                            get: { effective.onlyCompletePeriods }, set: { policy.onlyCompletePeriods = $0 }))
                            .disabled(policy.realTimeDirectQuery)
                        Toggle("Get the latest data in real time with DirectQuery", isOn: $policy.realTimeDirectQuery)
                        Toggle("Detect data changes", isOn: $detectChanges)
                        if detectChanges {
                            ModelColumnPicker(label: "Last-updated column", table: table,
                                              selection: Binding(get: { policy.detectChangesColumn ?? "" }, set: { policy.detectChangesColumn = $0 }),
                                              allowsNone: true, filter: { $0.dataType == .date || $0.dataType == .dateTime })
                                .frame(width: 220).padding(.leading, 20)
                                .help("A period is reloaded only when the latest value of this column has changed")
                        }
                    }
                    .toggleStyle(.checkbox)
                    Hairline()
                    if problems.isEmpty { windowSummary }
                    parameters
                }
            }
            .padding(Design.Space.l)
        } footer: {
            DialogProblemLine(problem: problems.first)
            ModelingSheetButtons(confirmTitle: "Apply", confirmDisabled: !problems.isEmpty, confirm: save)
        }
    }

    private func period(_ title: String, count: Binding<Int>, unit: Binding<String>, tail: String) -> some View {
        HStack(spacing: Design.Space.s) {
            Text(title).font(Design.Typeface.body).frame(width: 150, alignment: .leading)
            TextField("1", value: count, format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
            Picker(title, selection: unit) {
                ForEach(IncrementalRefreshLogic.units, id: \.self) { Text(IncrementalRefreshLogic.unitTitle($0, count: 2).capitalized).tag($0) }
            }.labelsHidden().frame(width: 110)
            Text(tail).font(Design.Typeface.caption).foregroundStyle(.secondary)
        }
    }

    private var windowSummary: some View {
        let w = IncrementalRefreshLogic.windows(effective, now: Date())
        func text(_ d: Date) -> String { String(DateParsing.isoString(d).prefix(10)) }
        return VStack(alignment: .leading, spacing: 2) {
            Text("Refreshed today, the model would keep rows from \(text(w.archiveStart)) and reload rows from \(text(w.refreshStart)) up to \(text(w.end)).")
            if effective.realTimeDirectQuery { Text("Rows from \(text(w.end)) onward are read live from the source.") }
        }
        .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var parameters: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            if missing.isEmpty {
                Label("RangeStart and RangeEnd parameters exist.", systemImage: "checkmark.circle")
                    .font(Design.Typeface.caption).foregroundStyle(Design.Palette.positive)
            } else {
                HStack {
                    Label("The \(missing.joined(separator: " and ")) Date/Time parameter\(missing.count == 1 ? " is" : "s are") missing.", systemImage: "exclamationmark.triangle")
                        .font(Design.Typeface.caption).foregroundStyle(Design.Palette.caution)
                    Button("Create") { createParameters() }
                }
            }
            if let q = sourceQuery, !IncrementalRefreshLogic.queryUsesRange(q.mScript), !policy.dateColumn.isEmpty {
                Text("The query “\(q.name)” doesn't filter on the parameters yet. Add this step in the Power Query editor:")
                    .font(Design.Typeface.caption).foregroundStyle(Design.Palette.caution).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top) {
                    Text(IncrementalRefreshLogic.filterStep(column: policy.dateColumn)).font(Design.Typeface.mono).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    IconButton("doc.on.doc", help: "Copy the filter step") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(IncrementalRefreshLogic.filterStep(column: policy.dateColumn), forType: .string)
                    }
                }
            }
        }
    }

    private func createParameters() {
        let w = IncrementalRefreshLogic.windows(effective, now: Date())
        let names = missing
        store.mutate("Create Range Parameters", invalidates: .layout) { d in
            for name in names {
                d.queries.append(IncrementalRefreshLogic.parameterQuery(name, value: name == "RangeStart" ? w.refreshStart : w.end))
            }
        }
    }

    private func save() {
        guard problems.isEmpty else { return }
        let new: IncrementalRefreshPolicy? = enabled ? effective : nil
        ModelOps.updateTable(store, table, name: enabled ? "Set Incremental Refresh" : "Remove Incremental Refresh", invalidates: .layout) {
            $0.incrementalRefresh = new
        }
        store.dismissSheet()
    }
}

/// Manage aggregations: map an aggregation table's columns to a detail table.
struct AggregationsSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var aggTable: String
    @State private var rows: [AggregationLogic.Row]

    init(model: SemanticModel, table: String?) {
        let name = model.aggregations.first.map(\.aggTable).flatMap { model.table($0)?.name }
            ?? table.flatMap { model.table($0)?.name } ?? model.tables.first?.name ?? ""
        _aggTable = State(initialValue: name)
        _rows = State(initialValue: model.table(name).map { AggregationLogic.rows(for: $0, model: model) } ?? [])
    }

    private var modelTable: ModelTable { store.model.table(aggTable) ?? ModelTable(name: aggTable) }
    private var problems: [String] { AggregationLogic.problems(rows, aggTable: modelTable, model: store.model) }

    var body: some View {
        ModelingSheet(title: "Manage aggregations",
                      subtitle: "An aggregation table holds pre-summarised rows. When a query can be answered from it, the engine uses it instead of the detail table.",
                      width: 760, height: 520) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Design.Space.s) {
                    Text("Aggregation table").font(Design.Typeface.body)
                    ModelTablePicker(label: "Aggregation table", selection: $aggTable).frame(width: 220)
                    Spacer()
                    Button("Clear All") { for i in rows.indices { rows[i].summarization = .none } }
                        .disabled(!rows.contains { $0.summarization != .none })
                }
                .padding(Design.Space.m)
                Hairline()
                HStack(spacing: Design.Space.s) {
                    Text("Aggregation column").frame(width: 170, alignment: .leading)
                    Text("Summarization").frame(width: 150, alignment: .leading)
                    Text("Detail table").frame(width: 170, alignment: .leading)
                    Text("Detail column").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
                .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
                Hairline()
                ScrollView {
                    LazyVStack(spacing: 2) { ForEach($rows) { $row in line($row) } }
                        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
                }
            }
            .onChange(of: aggTable) { _, _ in rows = AggregationLogic.rows(for: modelTable, model: store.model) }
        } footer: {
            DialogProblemLine(problem: problems.first)
            ModelingSheetButtons(confirmTitle: "Apply All", confirmDisabled: !problems.isEmpty, confirm: save)
        }
    }

    private func line(_ row: Binding<AggregationLogic.Row>) -> some View {
        let r = row.wrappedValue
        return HStack(spacing: Design.Space.s) {
            Text(r.column).font(Design.Typeface.body).lineLimit(1).frame(width: 170, alignment: .leading)
            Picker("Summarization", selection: row.summarization) {
                ForEach(AggregationLogic.Summarization.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 150)
            if r.summarization == .none {
                Spacer(minLength: 0)
            } else {
                ModelTablePicker(label: "Detail table", selection: Binding(get: { r.detailTable }, set: { new in
                    if new != r.detailTable { row.wrappedValue.detailTable = new; row.wrappedValue.detailColumn = "" }
                }), tables: store.model.tables.filter { !ModelDAX.same($0.name, aggTable) }).frame(width: 170)
                if r.summarization.needsDetailColumn {
                    ModelColumnPicker(label: "Detail column", table: r.detailTable, selection: row.detailColumn).frame(maxWidth: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func save() {
        guard problems.isEmpty else { return }
        let table = aggTable, mapped = rows
        store.mutate("Manage Aggregations", invalidates: .model) { AggregationLogic.apply(mapped, aggTable: table, to: &$0.model) }
        store.dismissSheet()
    }
}
