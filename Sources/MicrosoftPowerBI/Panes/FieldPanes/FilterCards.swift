import SwiftUI
import FacetCore
import FacetDesign

/// What the Filters pane's cards show, kept apart from the views so it can be tested.
enum FilterCardLogic {
    /// A control in a card's header.
    enum Control: Equatable { case clear, lock, hide }

    /// The card's title: the name the author gave it, or the field's.
    static func title(_ f: FilterSpec) -> String { f.displayName ?? f.field.caption }

    /// The header's controls. While the pointer is over the card: clear (when the filter restricts
    /// anything), lock and hide. Otherwise only a lock or hide that is on stays, as a reminder.
    static func controls(_ f: FilterSpec, hovering: Bool) -> [Control] {
        if hovering { return (f.isEmpty ? [] : [.clear]) + [.lock, .hide] }
        return (f.isLocked ? [.lock] : []) + (f.isHidden ? [.hide] : [])
    }

    static func symbol(_ c: Control, _ f: FilterSpec) -> String {
        switch c {
        case .clear: return "eraser"
        case .lock: return f.isLocked ? "lock.fill" : "lock.open"
        case .hide: return f.isHidden ? "eye.slash" : "eye"
        }
    }

    static func help(_ c: Control, _ f: FilterSpec) -> String {
        switch c {
        case .clear: return "Clear filter"
        case .lock: return f.isLocked ? "Unlock filter, so readers can change it" : "Lock filter, so readers can't change it"
        case .hide: return f.isHidden ? "Show filter to readers" : "Hide filter from readers"
        }
    }

    /// True when a filter card matches the pane's search: its title, field or table contains every
    /// word of the query, ignoring case and accents. An empty query matches everything.
    static func matches(_ f: FilterSpec, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = [title(f), f.field.caption, f.field.name, f.field.table].joined(separator: " ")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The filters a section lists under the search, each with its place in the section's own list
    /// (moving a card moves it among all of them).
    static func listed(_ filters: [FilterSpec], query: String) -> [(position: Int, filter: FilterSpec)] {
        filters.enumerated().filter { matches($0.element, query: query) }.map { (position: $0.offset, filter: $0.element) }
    }
}

/// One filter as a Power BI filter card: its name and what it keeps; clear, lock and hide on
/// hover; options; and its editor when expanded.
struct FilterCard: View {
    let filter: FilterSpec
    let scope: FilterSpec.Scope
    let position: Int
    let count: Int
    @EnvironmentObject var store: DocumentStore
    @State private var expanded = false
    @State private var renaming = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Hairline()
                FilterEditor(filter: filter, scope: scope).padding(Design.Space.s)
            }
        }
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            .fill(hovering || expanded ? Design.Palette.fillStrong : Design.Palette.fill))
        .onHover { hovering = $0 }
        .animation(Design.Motion.quick, value: hovering)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Design.Space.xxs) {
            if renaming {
                InlineRename(text: FilterCardLogic.title(filter), isEditing: $renaming, font: Design.Typeface.bodyStrong) { name in
                    store.renameFilter(id: filter.id, scope: scope, to: name)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button { withAnimation(Design.Motion.quick) { expanded.toggle() } } label: {
                    VStack(alignment: .leading, spacing: Design.Space.xxs) {
                        Text(FilterCardLogic.title(filter)).font(Design.Typeface.bodyStrong).lineLimit(1).truncationMode(.middle)
                        Text(FilterTools.summary(filter)).font(Design.Typeface.caption)
                            .foregroundStyle(filter.isEmpty ? Color.secondary : Color.primary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded { renaming = true })
                .accessibilityLabel("\(FilterCardLogic.title(filter)), \(FilterTools.summary(filter))")
                .accessibilityHint(expanded ? "Collapses the filter" : "Expands the filter")
            }
            ForEach(FilterCardLogic.controls(filter, hovering: hovering), id: \.self) { control in
                MiniIconButton(FilterCardLogic.symbol(control, filter), help: FilterCardLogic.help(control, filter),
                               isOn: control == .lock && filter.isLocked || control == .hide && filter.isHidden) { run(control) }
            }
            options
            MiniIconButton(expanded ? "chevron.up" : "chevron.down", help: expanded ? "Collapse filter card" : "Expand filter card") {
                withAnimation(Design.Motion.quick) { expanded.toggle() }
            }
        }
        .padding(.leading, Design.Space.s).padding(.trailing, Design.Space.xxs).padding(.vertical, Design.Space.xs + Design.Space.xxs)
    }

    private var options: some View {
        Menu {
            Button("Rename") { renaming = true }
            if filter.displayName != nil {
                Button("Use the Field's Name") { store.renameFilter(id: filter.id, scope: scope, to: "") }
            }
            Button("Move Up") { store.moveFilter(id: filter.id, scope: scope, by: -1) }.disabled(position == 0)
            Button("Move Down") { store.moveFilter(id: filter.id, scope: scope, by: 1) }.disabled(position >= count - 1)
            Divider()
            // The hover controls, here too, for the keyboard and VoiceOver.
            Button("Clear Filter") { run(.clear) }.disabled(filter.isEmpty)
            Button(filter.isLocked ? "Unlock Filter" : "Lock Filter") { run(.lock) }
            Button(filter.isHidden ? "Show Filter" : "Hide Filter") { run(.hide) }
            Divider()
            if filter.kind == .basic {
                Button(filter.requireSingleSelection ? "Allow multiple selections" : "Require single selection") {
                    edit { $0 = FilterTools.requiringSingleSelection($0, !$0.requireSingleSelection) }
                }
                Button(filter.isInverted ? "Keep selected values" : "Exclude selected values") { edit { $0.isInverted.toggle() } }
            }
            if filter.kind == .advanced {
                Button(filter.conditionsUseOr ? "Match all conditions" : "Match any condition") { edit { $0.conditionsUseOr.toggle() } }
            }
            Button("Remove Filter", role: .destructive) { store.removeFilter(id: filter.id, scope: scope) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More filter options")
        .accessibilityLabel("More filter options")
    }

    private func run(_ control: FilterCardLogic.Control) {
        switch control {
        case .clear: edit(name: "Clear Filter") { $0 = FilterTools.cleared($0) }
        case .lock: edit(name: filter.isLocked ? "Unlock Filter" : "Lock Filter") { $0.isLocked.toggle() }
        case .hide: edit(name: filter.isHidden ? "Show Filter" : "Hide Filter") { $0.isHidden.toggle() }
        }
    }

    private func edit(name: String = "Change Filter", _ body: (inout FilterSpec) -> Void) {
        store.updateFilter(id: filter.id, scope: scope, name: name, body)
    }
}
