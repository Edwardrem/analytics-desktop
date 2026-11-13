import SwiftUI
import FacetCore
import FacetDesign
import FacetInterop

/// Left-hand explorer of the TMDL view: every object kind in the semantic model. Selecting highlights,
/// double-clicking or dragging onto the editor scripts the object.
struct TMDLObjectTree: View {
    enum Section: String, CaseIterable, Identifiable {
        case tables = "Tables", relationships = "Relationships", roles = "Roles"
        case perspectives = "Perspectives", cultures = "Cultures", functions = "Functions", expressions = "Expressions"
        var id: String { rawValue }
    }

    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: TMDLViewSession
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    @State private var collapsedSections: Set<Section> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.Space.xs) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                TextField("Search the model", text: $search)
                    .textFieldStyle(.plain)
                    .font(Design.Typeface.body)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.s)
            Hairline()
            if TMDLViewSession.hasObjects(store.model) || !store.doc.queries.isEmpty {
                tree
            } else {
                EmptyState(systemImage: "point.3.connected.trianglepath.dotted", title: "Nothing to script yet",
                           message: "Add data to the model, then script and edit it here as TMDL.")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Design.Palette.surface)
    }

    private func matches(_ name: String) -> Bool { search.isEmpty || name.localizedCaseInsensitiveContains(search) }

    @ViewBuilder
    private var tree: some View {
        let model = store.model
        let shared = TMDL.sharedExpressions(model: model, queries: store.doc.queries)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                modelRoot(model)
                sectionRow(.tables, count: model.tables.count + model.calculationGroups.count)
                if !collapsedSections.contains(.tables) { tableRows(model) }
                sectionRow(.relationships, count: model.relationships.count)
                if !collapsedSections.contains(.relationships) { relationshipRows(model) }
                sectionRow(.roles, count: model.roles.count)
                if !collapsedSections.contains(.roles) { roleRows(model) }
                sectionRow(.perspectives, count: model.perspectives.count)
                if !collapsedSections.contains(.perspectives) { perspectiveRows(model) }
                sectionRow(.cultures, count: model.translations.count)
                if !collapsedSections.contains(.cultures) { cultureRows(model) }
                sectionRow(.functions, count: model.functions.count)
                if !collapsedSections.contains(.functions) { functionRows(model) }
                sectionRow(.expressions, count: shared.count)
                if !collapsedSections.contains(.expressions) { expressionRows(shared) }
            }
            .padding(.vertical, Design.Space.xs)
        }
    }

    // MARK: Rows

    private func modelRoot(_ model: SemanticModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            refRow(.model, icon: "cube", name: model.name, indent: 0, bold: true)
            if matches("properties") || matches(model.name) {
                refRow(.modelProperties, icon: "list.bullet.rectangle", name: "Properties", indent: 1)
            }
        }
    }

    @ViewBuilder
    private func tableRows(_ model: SemanticModel) -> some View {
        ForEach(model.tables.filter { matches($0.name) || children($0).contains(where: matches) }) { table in
            let open = !search.isEmpty || !collapsed.contains(table.name)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Design.Space.xs) {
                    tableRow(table, open: open)
                }
                if open {
                    ForEach(table.measures.filter { matches($0.name) || matches(table.name) }) { m in
                        refRow(.measure(table: table.name, name: m.name), icon: "sum", name: m.name, indent: 2)
                    }
                    ForEach(table.columns.filter { matches($0.name) || matches(table.name) }) { c in
                        refRow(.column(table: table.name, name: c.name), icon: DAXResultFormat.glyph(for: c.dataType), name: c.name, indent: 2)
                    }
                    ForEach(table.hierarchies.filter { matches($0.name) || matches(table.name) }) { h in
                        refRow(.hierarchy(table: table.name, name: h.name), icon: "list.bullet.indent", name: h.name, indent: 2)
                    }
                }
            }
        }
        ForEach(model.calculationGroups.filter { matches($0.name) }) { group in
            refRow(.calculationGroup(group.name), icon: "function", name: group.name, indent: 1)
        }
    }

    private func tableRow(_ table: ModelTable, open: Bool) -> some View {
        HStack(spacing: Design.Space.xs) {
            Button {
                if collapsed.contains(table.name) { collapsed.remove(table.name) } else { collapsed.insert(table.name) }
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.tertiary)
                    .frame(width: 12, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Collapse \(table.name)" : "Expand \(table.name)")
            .accessibilityLabel(open ? "Collapse \(table.name)" : "Expand \(table.name)")
            refRowContent(.table(table.name), icon: "tablecells", name: table.name, bold: true)
        }
        .padding(.leading, Design.Space.m)
    }

    private func relationshipRows(_ model: SemanticModel) -> some View {
        ForEach(model.relationships) { r in
            refRow(.relationship(r.id), icon: "link", name: "\(r.fromTable)[\(r.fromColumn)] → \(r.toTable)[\(r.toColumn)]", indent: 1)
        }
    }

    private func roleRows(_ model: SemanticModel) -> some View {
        ForEach(model.roles) { role in
            refRow(.role(role.name), icon: "person.badge.shield.checkmark", name: role.name, indent: 1)
        }
    }

    private func perspectiveRows(_ model: SemanticModel) -> some View {
        ForEach(model.perspectives) { p in
            refRow(.perspective(p.name), icon: "rectangle.3.group", name: p.name, indent: 1)
        }
    }

    private func cultureRows(_ model: SemanticModel) -> some View {
        ForEach(model.translations) { t in
            refRow(.culture(t.culture), icon: "globe", name: t.culture, indent: 1)
        }
    }

    private func functionRows(_ model: SemanticModel) -> some View {
        ForEach(model.functions) { f in
            refRow(.function(f.name), icon: "f.cursive.circle", name: f.name, indent: 1)
        }
    }

    private func expressionRows(_ shared: [QueryDefinition]) -> some View {
        ForEach(shared) { q in
            refRow(.expression(q.name), icon: "curlybraces", name: q.name, indent: 1)
        }
    }

    private func sectionRow(_ section: Section, count: Int) -> some View {
        let collapsedSection = collapsedSections.contains(section)
        return Button {
            if collapsedSection { collapsedSections.remove(section) } else { collapsedSections.insert(section) }
        } label: {
            HStack(spacing: Design.Space.xs) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(collapsedSection ? 0 : 90)).foregroundStyle(.tertiary)
                    .frame(width: 12, height: 20)
                Text(section.rawValue.uppercased()).font(Design.Typeface.section).kerning(0.6).foregroundStyle(.secondary)
                if count > 0 { Text("\(count)").font(Design.Typeface.caption).foregroundStyle(.tertiary).monospacedDigit() }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Design.Space.s)
        }
        .buttonStyle(.plain)
        .padding(.top, Design.Space.s)
        .help(collapsedSection ? "Expand \(section.rawValue)" : "Collapse \(section.rawValue)")
        .accessibilityLabel(collapsedSection ? "Expand \(section.rawValue)" : "Collapse \(section.rawValue)")
    }

    private func children(_ table: ModelTable) -> [String] {
        table.columns.map(\.name) + table.measures.map(\.name) + table.hierarchies.map(\.name)
    }

    /// A selectable, scriptable row: double-click or drag onto the editor to script it.
    private func refRow(_ ref: TMDLObjectRef, icon: String, name: String, indent: Int, bold: Bool = false) -> some View {
        refRowContent(ref, icon: icon, name: name, bold: bold)
            .padding(.leading, CGFloat(indent) * Design.Space.m)
    }

    private func refRowContent(_ ref: TMDLObjectRef, icon: String, name: String, bold: Bool) -> some View {
        let selected = session.selectedRef == ref
        return HStack(spacing: Design.Space.xs) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            Text(name).font(bold ? Design.Typeface.bodyStrong : Design.Typeface.body).lineLimit(1)
                .help("Double-click or drag into the editor to script \(TMDLViewSession.objectName(ref))")
            Spacer(minLength: 0)
        }
        .padding(.leading, Design.Space.s)
        .padding(.trailing, Design.Space.s)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { session.selectedRef = ref; session.script(ref) }
        .onTapGesture { session.selectedRef = ref }
        .draggable(ref.description)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Script \(TMDLViewSession.objectName(ref))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
