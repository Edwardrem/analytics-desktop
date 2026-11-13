import SwiftUI
import FacetCore
import FacetDesign
import FacetInterop

/// Left-hand explorer of the TMDL view: every object kind in the semantic model. Selecting highlights,
/// double-clicking or dragging onto the editor scripts the object.
struct TMDLObjectTree: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: TMDLViewSession
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    @State private var collapsedSections: Set<TMDLModelOutline.Section> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.Space.xs) {
                Image(systemName: "magnifyingglass").font(Design.Typeface.caption).foregroundStyle(.tertiary)
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
            let outline = TMDLModelOutline(model: store.model,
                                           shared: TMDL.sharedExpressions(model: store.model, queries: store.doc.queries),
                                           search: search)
            if outline.isEmpty {
                EmptyState(systemImage: "magnifyingglass", title: "No matches",
                           message: "Nothing in the model matches “\(outline.search)”.")
            } else {
                tree(outline)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Design.Palette.surface)
    }

    private func tree(_ outline: TMDLModelOutline) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                refRow(.model, icon: "cube", name: outline.model.name, indent: 0, bold: true)
                if outline.showsProperties {
                    refRow(.modelProperties, icon: "list.bullet.rectangle", name: "Properties", indent: 1)
                }
                ForEach(outline.visibleSections) { section in
                    sectionRow(section, count: outline.count(section))
                    // A search opens every section so its matches are in sight.
                    if outline.isSearching || !collapsedSections.contains(section) {
                        if section == .tables { tableRows(outline) }
                        ForEach(outline.rows(section)) { row in
                            refRow(row.ref, icon: row.icon, name: row.name, indent: 1)
                        }
                    }
                }
            }
            .padding(.vertical, Design.Space.xs)
        }
    }

    // MARK: Rows

    private func tableRows(_ outline: TMDLModelOutline) -> some View {
        ForEach(outline.tables) { table in
            let open = outline.isSearching || !collapsed.contains(table.name)
            tableRow(table, open: open)
            if open {
                ForEach(outline.members(of: table)) { row in
                    refRow(row.ref, icon: row.icon, name: row.name, indent: 2)
                }
            }
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

    private func sectionRow(_ section: TMDLModelOutline.Section, count: Int) -> some View {
        let isCollapsed = collapsedSections.contains(section)
        return Button {
            if isCollapsed { collapsedSections.remove(section) } else { collapsedSections.insert(section) }
        } label: {
            HStack(spacing: Design.Space.xs) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90)).foregroundStyle(.tertiary)
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
        .help(isCollapsed ? "Expand \(section.rawValue)" : "Collapse \(section.rawValue)")
        .accessibilityLabel(isCollapsed ? "Expand \(section.rawValue)" : "Collapse \(section.rawValue)")
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
                .help("Double-click or drag into the editor to script \(ref.displayName)")
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
        .onDrag { TMDLDragPayload.itemProvider(for: ref) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Script \(ref.displayName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
