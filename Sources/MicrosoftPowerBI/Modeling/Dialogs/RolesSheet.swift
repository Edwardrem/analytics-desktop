import SwiftUI
import FacetCore
import FacetDesign

/// Manage roles: row-level security filters (rule builder or DAX) and object-level security per role.
struct RolesSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var draft: [SecurityRole]
    @State private var selection: UUID?
    @State private var table = ""
    @State private var page = 0
    @State private var ruleColumn = ""
    @State private var ruleComparison = RoleLogic.Comparison.equals
    @State private var ruleValue = ""
    @State private var ruleAny = false
    @State private var ruleProblem: String?

    init(model: SemanticModel) {
        _draft = State(initialValue: model.roles)
        _selection = State(initialValue: model.roles.first?.id)
        _table = State(initialValue: model.tables.first?.name ?? "")
    }

    private var index: Int? { draft.firstIndex { $0.id == selection } }
    private var problems: [String] { RoleLogic.problems(draft, model: store.model) }

    var body: some View {
        ModelingSheet(title: "Manage security roles",
                      subtitle: "A role limits the rows and objects its members see. Assign people to roles after publishing.",
                      width: 860, height: 560) {
            HStack(spacing: 0) {
                NamedListColumn(items: draft.map { .init(id: $0.id, name: $0.name, symbol: "person.badge.key") },
                                selection: $selection, addHelp: "New role", width: 190,
                                onAdd: add,
                                onDelete: { id in draft.removeAll { $0.id == id }; selection = draft.first?.id },
                                onRename: { id, name in if let i = draft.firstIndex(where: { $0.id == id }) { draft[i].name = name } },
                                emptyTitle: "No roles")
                Hairline(vertical: true)
                if let i = index { detail(i) } else {
                    EmptyState(systemImage: "lock.shield", title: "Create a role", message: "Add a role, then choose which rows of each table it can see.")
                }
            }
        } footer: {
            DialogProblemLine(problem: problems.first)
            ModelingSheetButtons(confirmTitle: "Save", confirmDisabled: !problems.isEmpty, confirm: save)
        }
    }

    private func detail(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Section", selection: $page) {
                Text("Row filters").tag(0)
                Text("Object-level security").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 320)
            .padding(Design.Space.m)
            Hairline()
            if page == 0 { rowFilters(i) } else { objectSecurity(i) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rowFilters(_ i: Int) -> some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(store.model.tables) { t in
                        let filtered = !(draft[i].tableFilters[t.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                        HStack(spacing: Design.Space.s) {
                            Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : ModelGlyph.symbol(for: t))
                                .font(.system(size: 11)).foregroundStyle(filtered ? Color.accentColor : .secondary).frame(width: 14)
                            Text(t.name).font(Design.Typeface.body).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Design.Space.s).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                            .fill(ModelDAX.same(table, t.name) ? Color.accentColor.opacity(0.14) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { table = t.name; ruleColumn = ""; ruleProblem = nil }
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(Design.Space.xs)
            }
            .frame(width: 170)
            Hairline(vertical: true)
            VStack(alignment: .leading, spacing: Design.Space.m) {
                if store.model.table(table) != nil {
                    ModelField("Rows of \(table) this role can see (DAX, true keeps the row)") {
                        ModelingDAXEditor(text: draft[i].tableFilters[table] ?? "", kind: .rowFilter, homeTable: table, height: 130) { new in
                            guard let k = index else { return }
                            draft[k].tableFilters[table] = new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : new
                        }
                        .id("\(draft[i].id)|\(table)")
                    }
                    ruleBuilder(i)
                    Button("Clear filter") { draft[i].tableFilters[table] = nil }
                        .disabled((draft[i].tableFilters[table] ?? "").isEmpty)
                }
                Spacer(minLength: 0)
            }
            .padding(Design.Space.m)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func ruleBuilder(_ i: Int) -> some View {
        let column = store.model.table(table)?.column(ruleColumn)
        let comparisons = RoleLogic.Comparison.valid(for: column?.dataType ?? .text)
        return ModelField("Add a rule") {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                HStack(spacing: Design.Space.s) {
                    ModelColumnPicker(label: "Column", table: table, selection: $ruleColumn).frame(width: 140)
                    Picker("Comparison", selection: $ruleComparison) {
                        ForEach(comparisons) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 130)
                    TextField("Value", text: $ruleValue).textFieldStyle(.roundedBorder).frame(minWidth: 80)
                }
                HStack(spacing: Design.Space.s) {
                    Picker("Combine", selection: $ruleAny) {
                        Text("And").tag(false)
                        Text("Or").tag(true)
                    }.labelsHidden().frame(width: 70).help("How the rule joins the filter already there")
                    Button("Add Rule") { addRule(i, column: column, comparisons: comparisons) }.disabled(column == nil)
                    if let ruleProblem { Text(ruleProblem).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative) }
                }
            }
        }
    }

    private func addRule(_ i: Int, column: ModelColumn?, comparisons: [RoleLogic.Comparison]) {
        guard let column else { return }
        let comparison = comparisons.contains(ruleComparison) ? ruleComparison : .equals
        guard let rule = RoleLogic.rule(column: column.name, type: column.dataType, comparison: comparison, value: ruleValue) else {
            ruleProblem = "“\(ruleValue)” isn't a \(column.dataType.displayName.lowercased()) value."
            return
        }
        ruleProblem = nil
        draft[i].tableFilters[table] = RoleLogic.combine(draft[i].tableFilters[table] ?? "", with: rule, any: ruleAny)
        ruleValue = ""
    }

    private func objectSecurity(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Checked tables and columns are visible to this role. Unchecked ones don't exist for its members.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
                .padding(.horizontal, Design.Space.m).padding(.top, Design.Space.s)
            ModelObjectChecklist(includeMeasures: false, state: { id in
                let (t, member) = ModelNames.split(id)
                if RoleLogic.isTableHidden(draft[i], t) { return .none }
                if let member { return RoleLogic.isColumnHidden(draft[i], table: t, column: member) ? .none : .all }
                let hidden = (store.model.table(t)?.columns ?? []).filter { RoleLogic.isColumnHidden(draft[i], table: t, column: $0.name) }.count
                return hidden == 0 ? .all : .some
            }, toggle: { id in
                let (t, member) = ModelNames.split(id)
                if let member {
                    if RoleLogic.isTableHidden(draft[i], t) { return }
                    RoleLogic.setColumn(table: t, column: member, hidden: !RoleLogic.isColumnHidden(draft[i], table: t, column: member), in: &draft[i])
                } else {
                    let visible = !RoleLogic.isTableHidden(draft[i], t)
                        && !(store.model.table(t)?.columns ?? []).contains { RoleLogic.isColumnHidden(draft[i], table: t, column: $0.name) }
                    if visible { RoleLogic.setTable(t, hidden: true, in: &draft[i]) }
                    else {
                        RoleLogic.setTable(t, hidden: false, in: &draft[i])
                        draft[i].hiddenColumns.removeAll { ModelDAX.same(ModelNames.split($0).table, t) }
                    }
                }
            })
        }
    }

    private func add() {
        var name = "Role"
        var n = 2
        while draft.contains(where: { ModelDAX.same($0.name, name) }) { name = "Role \(n)"; n += 1 }
        let role = SecurityRole(name: name)
        draft.append(role)
        selection = role.id
    }

    private func save() {
        guard problems.isEmpty else { return }
        let roles = RoleLogic.cleaned(draft, model: store.model)
        store.mutate("Manage Roles", invalidates: .model) { $0.model.roles = roles }
        // Roles being previewed may have been renamed or removed.
        let names = store.viewAsRoles.filter { n in roles.contains { ModelDAX.same($0.name, n) } }
        if names != store.viewAsRoles { store.viewAsRoles = names }
        store.dismissSheet()
    }
}

/// View as: preview the report as one or more roles, or as a named user.
struct ViewAsSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var roles: Set<String>
    @State private var otherUser: Bool
    @State private var user: String

    init(roles: [String], user: String) {
        _roles = State(initialValue: Set(roles))
        _otherUser = State(initialValue: !user.isEmpty)
        _user = State(initialValue: user)
    }

    private var chosen: [String] { store.model.roles.map(\.name).filter(roles.contains) }
    private var problem: String? { RoleLogic.viewAsProblem(roles: chosen, user: otherUser ? user : "", model: store.model) }

    var body: some View {
        ModelingSheet(title: "View as roles", subtitle: "See the report the way members of these roles would.", width: 420, height: nil) {
            VStack(alignment: .leading, spacing: Design.Space.s) {
                Toggle("None", isOn: Binding(get: { roles.isEmpty && !otherUser }, set: { if $0 { roles = []; otherUser = false } }))
                Toggle("Other user", isOn: $otherUser)
                if otherUser {
                    TextField("name@example.com", text: $user).textFieldStyle(.roundedBorder).padding(.leading, 20)
                        .help("Returned by USERNAME and USERPRINCIPALNAME")
                }
                Hairline()
                if store.model.roles.isEmpty {
                    Text("No roles are defined. Use Manage roles to add one.").font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
                ForEach(store.model.roles) { r in
                    Toggle(r.name, isOn: Binding(get: { roles.contains(r.name) }, set: { on in
                        if on { roles.insert(r.name) } else { roles.remove(r.name) }
                    }))
                }
            }
            .toggleStyle(.checkbox)
            .padding(Design.Space.l)
        } footer: {
            DialogProblemLine(problem: problem)
            ModelingSheetButtons(confirmTitle: "OK", confirmDisabled: problem != nil) {
                let u = otherUser ? user.trimmingCharacters(in: .whitespaces) : ""
                if store.viewAsRoles != chosen { store.viewAsRoles = chosen }
                if store.viewAsUser != u { store.viewAsUser = u }
                if let summary = RoleLogic.viewAsSummary(roles: chosen, user: u) { store.status = StatusMessage(kind: .info, text: summary + ".") }
                else { store.status = StatusMessage(kind: .info, text: "Stopped viewing as a role.") }
                store.dismissSheet()
            }
        }
    }
}
