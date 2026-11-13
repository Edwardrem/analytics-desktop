import SwiftUI
import FacetCore
import FacetDesign

/// Mark as date table: choose the date column and validate it (unique, contiguous, no blanks).
struct DateTableSheet: View {
    @EnvironmentObject private var store: DocumentStore
    let table: String
    @State private var marked: Bool
    @State private var column: String
    @State private var check: DateTableLogic.Check?

    init(table: ModelTable) {
        self.table = table.name
        _marked = State(initialValue: true)
        _column = State(initialValue: table.dateColumn ?? DateTableLogic.candidates(table).first?.name ?? "")
    }

    private var modelTable: ModelTable { store.model.table(table) ?? ModelTable(name: table) }
    private var problem: String? {
        guard marked else { return nil }
        if DateTableLogic.candidates(modelTable).isEmpty { return "\(table) has no Date or Date/Time column." }
        if column.isEmpty { return "Choose a date column." }
        guard let check else { return nil }
        return check.problems.first
    }

    var body: some View {
        ModelingSheet(title: "Mark as a date table",
                      subtitle: "Time intelligence uses this table's date column. It must hold one row for every day, with no blanks or repeats.",
                      width: 520, height: nil) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                Toggle("Mark \(table) as a date table", isOn: $marked).toggleStyle(.switch)
                if marked {
                    ModelField("Date column") {
                        ModelColumnPicker(label: "Date column", table: table, selection: $column,
                                          filter: { $0.dataType == .date || $0.dataType == .dateTime }).frame(width: 240)
                    }
                    if check == nil, !column.isEmpty {
                        HStack(spacing: Design.Space.s) { ProgressView().controlSize(.small); Text("Validating…").font(Design.Typeface.caption).foregroundStyle(.secondary) }
                    } else if let check {
                        if check.isValid {
                            Label("Validated successfully. \(DateTableLogic.summary(check))", systemImage: "checkmark.circle")
                                .font(Design.Typeface.caption).foregroundStyle(Design.Palette.positive)
                        } else {
                            VStack(alignment: .leading, spacing: Design.Space.xs) {
                                ForEach(check.problems, id: \.self) { p in
                                    Label(p, systemImage: "exclamationmark.circle").font(Design.Typeface.caption)
                                        .foregroundStyle(Design.Palette.negative).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } else if modelTable.isDateTable {
                    Text("Time intelligence will stop treating \(table) as the calendar.").font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Design.Space.l)
        } footer: {
            ModelingSheetButtons(confirmTitle: "Save", confirmDisabled: problem != nil || (marked && check == nil), confirm: save)
        }
        .task(id: column) { await validate() }
    }

    private func validate() async {
        check = nil
        guard !column.isEmpty, let c = modelTable.column(column) else { return }
        let data = DialogTarget.data(store)
        let key = data.tables.keys.first { ModelDAX.same($0, table) }
        let values = key.flatMap { data.tables[$0]?.column(column)?.values } ?? []
        let type = c.dataType, name = column
        let result = await Task.detached(priority: .userInitiated) { DateTableLogic.validate(values, type: type, column: name) }.value
        if !Task.isCancelled { check = result }
    }

    private func save() {
        guard problem == nil else { return }
        let new: String? = marked ? column : nil
        ModelOps.updateTable(store, table, name: marked ? "Mark as Date Table" : "Unmark Date Table") { $0.dateColumn = new }
        store.dismissSheet()
    }
}

/// Calendars of one table, for calendar-based time intelligence.
struct CalendarsSheet: View {
    @EnvironmentObject private var store: DocumentStore
    let table: String
    @State private var draft: [CalendarDefinition]
    @State private var selection: UUID?

    init(table: ModelTable) {
        self.table = table.name
        _draft = State(initialValue: table.calendars)
        _selection = State(initialValue: table.calendars.first?.id)
    }

    private var modelTable: ModelTable { store.model.table(table) ?? ModelTable(name: table) }
    private var index: Int? { draft.firstIndex { $0.id == selection } }
    private var problems: [String] { CalendarLogic.problems(draft, table: modelTable, model: store.model) }

    var body: some View {
        ModelingSheet(title: "Calendars in \(table)",
                      subtitle: "A calendar maps this table's columns to time units, so time intelligence can follow a fiscal or retail year. Use its name in place of a date column.",
                      width: 680, height: 440) {
            HStack(spacing: 0) {
                NamedListColumn(items: draft.map { .init(id: $0.id, name: $0.name, symbol: "calendar") }, selection: $selection,
                                addHelp: "New calendar", width: 200,
                                onAdd: {
                                    let c = CalendarLogic.make(in: modelTable, model: store.model, alongside: draft)
                                    draft.append(c); selection = c.id
                                },
                                onDelete: { id in draft.removeAll { $0.id == id }; selection = draft.first?.id },
                                onRename: { id, name in if let i = draft.firstIndex(where: { $0.id == id }) { draft[i].name = name } },
                                emptyTitle: "No calendars")
                Hairline(vertical: true)
                if let i = index { detail(i) } else {
                    EmptyState(systemImage: "calendar", title: "Create a calendar", message: "Add one, then map its year, quarter, month, week and date columns.")
                }
            }
        } footer: {
            DialogProblemLine(problem: problems.first)
            ModelingSheetButtons(confirmTitle: "Save", confirmDisabled: !problems.isEmpty, confirm: save)
        }
    }

    private func detail(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            ModelField("Name") { TextField("Fiscal", text: $draft[i].name).textFieldStyle(.roundedBorder).frame(width: 240) }
            ForEach(CalendarDefinition.units, id: \.self) { unit in
                HStack {
                    Text(CalendarLogic.unitTitle(unit)).font(Design.Typeface.body).frame(width: 70, alignment: .leading)
                    ModelColumnPicker(label: CalendarLogic.unitTitle(unit), table: table,
                                      selection: Binding(get: { draft[i].columnsByUnit[unit] ?? "" },
                                                         set: { draft[i].columnsByUnit[unit] = $0.isEmpty ? nil : $0 }),
                                      allowsNone: true).frame(width: 220)
                }
            }
            HStack {
                Text("Year starts").font(Design.Typeface.body).frame(width: 70, alignment: .leading)
                Picker("Year starts", selection: $draft[i].fiscalYearStartMonth) {
                    ForEach(1...12, id: \.self) { m in Text(Calendar.utc.monthSymbols[m - 1]).tag(m) }
                }.labelsHidden().frame(width: 220)
            }
            Text("In DAX: TOTALYTD([Sales], \(draft[i].name))").font(Design.Typeface.mono).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(Design.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func save() {
        guard problems.isEmpty else { return }
        let calendars = CalendarLogic.cleaned(draft)
        ModelOps.updateTable(store, table, name: "Edit Calendars") { $0.calendars = calendars }
        store.dismissSheet()
    }
}
