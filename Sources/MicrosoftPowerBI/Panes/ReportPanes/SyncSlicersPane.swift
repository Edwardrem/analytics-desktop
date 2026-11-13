import SwiftUI
import FacetCore
import FacetDesign

// MARK: - Sync model

/// How slicer syncing maps onto the document model.
///
/// Slicers are in step across pages when they show the same field and share a group name.
/// `VisualSpec.syncGroup` is what the store uses to copy selections between slicers, so it is only
/// set while "Sync filter changes" is on; the group name itself always lives in `format["sync"]["group"]`.
enum SlicerSync {
    static let card = "sync"

    /// Identity of the field(s) a slicer shows, ignoring presentation.
    static func fieldKey(_ v: VisualSpec) -> String? {
        let fields = v.fields(.field)
        return fields.isEmpty ? nil : fields.map { "\($0.table)|\($0.name)" }.joined(separator: "\u{1F}")
    }
    static func group(_ v: VisualSpec) -> String? {
        if let g = v.syncGroup, !g.isEmpty { return g }
        if let g = v.fmt(card, "group")?.stringValue, !g.isEmpty { return g }
        return nil
    }
    static func syncsFilters(_ v: VisualSpec) -> Bool { v.fmtBool(card, "filterChanges", true) }
    static func syncsFields(_ v: VisualSpec) -> Bool { v.fmtBool(card, "fieldChanges", false) }
    static func isCopy(_ v: VisualSpec) -> Bool { v.fmtBool(card, "isCopy", false) }

    static func setGroup(_ v: inout VisualSpec, _ name: String?) {
        guard let name, !name.isEmpty else {
            v.syncGroup = nil
            v.setFmt(card, "group", nil)
            return
        }
        v.setFmt(card, "group", .string(name))
        v.syncGroup = syncsFilters(v) ? name : nil
    }

    struct Member: Identifiable {
        var page: Page
        var visual: VisualSpec
        var id: UUID { visual.id }
    }
    struct Group: Identifiable {
        var name: String
        var field: String
        var members: [Member]
        var id: String { name }
    }
    /// Every sync group in the report with the slicers that belong to it, in page order.
    static func groups(in report: Report) -> [Group] {
        var order: [String] = []
        var byName: [String: Group] = [:]
        for page in report.pages {
            for v in page.visuals where v.type.isSlicer {
                guard let name = group(v) else { continue }
                if byName[name] == nil {
                    order.append(name)
                    byName[name] = Group(name: name, field: v.fields(.field).map(\.caption).joined(separator: ", "), members: [])
                }
                byName[name]?.members.append(Member(page: page, visual: v))
            }
        }
        return order.compactMap { byName[$0] }
    }

    /// The slicer on `page` that stands for `source` there: itself on its own page, otherwise a slicer on
    /// the same field — preferring one already in the same group, then one that isn't synced at all.
    static func counterpart(of source: VisualSpec, on page: Page) -> VisualSpec? {
        if page.visual(source.id) != nil { return source }
        guard let key = fieldKey(source) else { return nil }
        let same = page.visuals.filter { $0.type.isSlicer && fieldKey($0) == key }
        if let g = group(source), let member = same.first(where: { group($0) == g }) { return member }
        return same.first { group($0) == nil }
    }
    static func isSynced(_ source: VisualSpec, on page: Page) -> Bool {
        guard let g = group(source), let other = counterpart(of: source, on: page) else { return false }
        return group(other) == g
    }
}

extension DocumentStore {
    private func locate(_ id: UUID, in d: FacetDocument) -> (page: Int, visual: Int)? {
        for p in d.report.pages.indices {
            if let v = d.report.pages[p].visuals.firstIndex(where: { $0.id == id }) { return (p, v) }
        }
        return nil
    }

    /// A copy of a slicer placed on another page.
    private static func slicerCopy(of source: VisualSpec, for page: Page, hidden: Bool) -> VisualSpec {
        var c = source
        c.id = UUID()
        c.isHidden = hidden
        c.groupID = nil
        c.mobileFrame = nil
        c.zIndex = (page.visuals.map(\.zIndex).max() ?? 0) + 1
        c.tabOrder = page.visuals.count
        c.frame.width = min(c.frame.width, page.size.width)
        c.frame.height = min(c.frame.height, page.size.height)
        c.frame.x = max(0, min(c.frame.x, page.size.width - c.frame.width))
        c.frame.y = max(0, min(c.frame.y, page.size.height - c.frame.height))
        c.setFmt(SlicerSync.card, "isCopy", .bool(true))
        return c
    }

    /// Sync (or stop syncing) a slicer with a page. Syncing a page that has no slicer on the same field
    /// puts a hidden copy there; un-syncing removes such a hidden copy and otherwise just leaves the group.
    func setSlicerSync(_ slicerID: UUID, pageID: UUID, synced: Bool) {
        mutate(synced ? "Sync Slicer" : "Stop Syncing Slicer", invalidates: .visuals(nil)) { d in
            guard let at = locate(slicerID, in: d), let pi = d.report.pages.firstIndex(where: { $0.id == pageID }) else { return }
            if synced {
                if SlicerSync.group(d.report.pages[at.page].visuals[at.visual]) == nil {
                    let source = d.report.pages[at.page].visuals[at.visual]
                    let base = source.fields(.field).first?.caption ?? source.name
                    let taken = SlicerSync.groups(in: d.report).filter { g in
                        g.members.contains { SlicerSync.fieldKey($0.visual) != SlicerSync.fieldKey(source) }
                    }.map(\.name)
                    SlicerSync.setGroup(&d.report.pages[at.page].visuals[at.visual], taken.uniqueName(base))
                }
                let source = d.report.pages[at.page].visuals[at.visual]
                guard pi != at.page, let name = SlicerSync.group(source) else { return }
                if let other = SlicerSync.counterpart(of: source, on: d.report.pages[pi]),
                   let vi = d.report.pages[pi].visuals.firstIndex(where: { $0.id == other.id }) {
                    var v = d.report.pages[pi].visuals[vi]
                    v.setFmt(SlicerSync.card, "filterChanges", source.fmt(SlicerSync.card, "filterChanges"))
                    v.setFmt(SlicerSync.card, "fieldChanges", source.fmt(SlicerSync.card, "fieldChanges"))
                    SlicerSync.setGroup(&v, name)
                    v.slicerState = source.slicerState
                    d.report.pages[pi].visuals[vi] = v
                } else {
                    d.report.pages[pi].visuals.append(Self.slicerCopy(of: source, for: d.report.pages[pi], hidden: true))
                }
            } else {
                let source = d.report.pages[at.page].visuals[at.visual]
                if pi == at.page {
                    SlicerSync.setGroup(&d.report.pages[at.page].visuals[at.visual], nil)
                } else if SlicerSync.isSynced(source, on: d.report.pages[pi]),
                          let other = SlicerSync.counterpart(of: source, on: d.report.pages[pi]),
                          let vi = d.report.pages[pi].visuals.firstIndex(where: { $0.id == other.id }) {
                    if SlicerSync.isCopy(other), other.isHidden {
                        d.report.pages[pi].visuals.remove(at: vi)
                    } else {
                        SlicerSync.setGroup(&d.report.pages[pi].visuals[vi], nil)
                    }
                }
            }
        }
    }

    /// Show or hide a slicer's counterpart on a page. Showing it where there is none adds a copy.
    func setSlicerVisible(_ slicerID: UUID, pageID: UUID, visible: Bool) {
        mutate(visible ? "Show Slicer on Page" : "Hide Slicer on Page", invalidates: .visuals(nil)) { d in
            guard let at = locate(slicerID, in: d), let pi = d.report.pages.firstIndex(where: { $0.id == pageID }) else { return }
            let source = d.report.pages[at.page].visuals[at.visual]
            if let other = SlicerSync.counterpart(of: source, on: d.report.pages[pi]),
               let vi = d.report.pages[pi].visuals.firstIndex(where: { $0.id == other.id }) {
                if !visible, other.id != source.id, SlicerSync.isCopy(other), SlicerSync.group(other) == nil {
                    d.report.pages[pi].visuals.remove(at: vi)   // an unsynced, invisible copy has no purpose
                } else {
                    d.report.pages[pi].visuals[vi].isHidden = !visible
                }
            } else if visible {
                var copy = Self.slicerCopy(of: source, for: d.report.pages[pi], hidden: false)
                SlicerSync.setGroup(&copy, nil)
                d.report.pages[pi].visuals.append(copy)
            }
        }
    }

    /// Rename a slicer's sync group for every member (or start a group of one when it has none).
    func renameSyncGroup(of slicerID: UUID, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let source = visual(slicerID), SlicerSync.group(source) != name else { return }
        let old = SlicerSync.group(source)
        mutate("Rename Sync Group", invalidates: .visuals(nil)) { d in
            for p in d.report.pages.indices {
                for v in d.report.pages[p].visuals.indices {
                    let s = d.report.pages[p].visuals[v]
                    if s.id == slicerID || (old != nil && s.type.isSlicer && SlicerSync.group(s) == old) {
                        SlicerSync.setGroup(&d.report.pages[p].visuals[v], name)
                    }
                }
            }
        }
    }

    /// Set a sync option ("filterChanges" / "fieldChanges") for every slicer in the group.
    func setSyncOption(of slicerID: UUID, _ key: String, _ value: Bool) {
        guard let source = visual(slicerID), let name = SlicerSync.group(source) else { return }
        mutate("Change Slicer Sync", invalidates: .visuals(nil)) { d in
            for p in d.report.pages.indices {
                for v in d.report.pages[p].visuals.indices where d.report.pages[p].visuals[v].type.isSlicer
                    && SlicerSync.group(d.report.pages[p].visuals[v]) == name {
                    d.report.pages[p].visuals[v].setFmt(SlicerSync.card, key, .bool(value))
                    SlicerSync.setGroup(&d.report.pages[p].visuals[v], name)
                    if key == "filterChanges", value { d.report.pages[p].visuals[v].slicerState = source.slicerState }
                }
            }
        }
    }
}

/// Carries a field change on one synced slicer over to the rest of its group
/// (the "Sync field changes to other slicers" option).
struct SyncedFieldWatcher {
    private struct Snapshot: Equatable { var group: String; var fields: String }
    private var last: [UUID: Snapshot] = [:]

    private static func snapshot(_ report: Report) -> [UUID: Snapshot] {
        var out: [UUID: Snapshot] = [:]
        for p in report.pages {
            for v in p.visuals where v.type.isSlicer && SlicerSync.syncsFields(v) {
                guard let g = SlicerSync.group(v) else { continue }
                out[v.id] = Snapshot(group: g, fields: v.fields(.field).map(\.key).joined(separator: "\u{1F}"))
            }
        }
        return out
    }

    @MainActor
    mutating func reconcile(_ store: DocumentStore) {
        let now = Self.snapshot(store.report)
        let before = last
        last = now
        // Only follow fresh edits: after an undo the document is exactly what the user asked for.
        guard !before.isEmpty, store.redoName == nil else { return }
        var changedByGroup: [String: [UUID]] = [:]
        for (id, cur) in now {
            if let old = before[id], old.group == cur.group, old.fields != cur.fields { changedByGroup[cur.group, default: []].append(id) }
        }
        var updates: [UUID: [FieldRef]] = [:]
        for (group, changed) in changedByGroup where changed.count == 1 {
            guard let sourceID = changed.first, let source = store.visual(sourceID), let old = before[sourceID] else { continue }
            let fields = source.fields(.field)
            guard !fields.isEmpty else { continue }
            for (id, cur) in now where id != sourceID && cur.group == group && cur.fields == old.fields {
                updates[id] = fields
            }
        }
        guard !updates.isEmpty else { return }
        store.mutate("Sync Slicer Field", invalidates: .visuals(nil)) { d in
            for p in d.report.pages.indices {
                for v in d.report.pages[p].visuals.indices {
                    guard let fields = updates[d.report.pages[p].visuals[v].id] else { continue }
                    d.report.pages[p].visuals[v].setFields(.field, fields.map { var f = $0; f.id = UUID(); return f })
                    d.report.pages[p].visuals[v].slicerState = nil
                }
            }
        }
        last = Self.snapshot(store.report)
    }
}

// MARK: - Pane

struct SyncSlicersPane: View {
    @EnvironmentObject var store: DocumentStore
    @State private var groupDraft = ""
    @State private var advancedExpanded = false

    private var slicer: VisualSpec? {
        guard let v = store.selectedVisual, v.type.isSlicer else { return nil }
        return v
    }

    var body: some View {
        let groups = SlicerSync.groups(in: store.report)
        VStack(spacing: 0) {
            PaneHeader(title: "Sync Slicers", detail: "") { EmptyView() }
            Hairline()
            if let slicer, SlicerSync.fieldKey(slicer) != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        pagesTable(slicer)
                        Hairline().padding(.horizontal, Design.Space.m)
                        PaneSection(title: "Advanced", expanded: $advancedExpanded) { advanced(slicer) }
                        groupList(groups)
                    }
                }
                .onAppear { groupDraft = SlicerSync.group(slicer) ?? "" }
                .onChange(of: slicer.id) { _, _ in groupDraft = SlicerSync.group(slicer) ?? "" }
                .onChange(of: SlicerSync.group(slicer)) { _, g in groupDraft = g ?? "" }
            } else if groups.isEmpty {
                EmptyState(systemImage: "arrow.triangle.2.circlepath", title: emptyTitle, message: emptyMessage)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        EmptyState(systemImage: "arrow.triangle.2.circlepath", title: emptyTitle, message: emptyMessage)
                            .frame(height: 190)
                        Hairline().padding(.horizontal, Design.Space.m)
                        groupList(groups)
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        if let v = store.selectedVisual, v.type.isSlicer { return "Add a field to this slicer" }
        return "Select a slicer"
    }
    private var emptyMessage: String {
        if let v = store.selectedVisual, v.type.isSlicer { return "Once the slicer shows a field, choose the pages it should stay in step with." }
        return "Choose which pages a slicer applies to, and where it is visible. A synced slicer keeps the same selection on every page it is synced with."
    }

    // MARK: Pages × Sync / Visible

    private func pagesTable(_ slicer: VisualSpec) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                SectionLabel("Page")
                Image(systemName: "arrow.triangle.2.circlepath").frame(width: 44)
                    .help("Sync: the slicer's selection applies on this page").accessibilityLabel("Sync")
                Image(systemName: "eye").frame(width: 44)
                    .help("Visible: the slicer is shown on this page").accessibilityLabel("Visible")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(height: 28)
            ForEach(store.report.pages) { page in
                let other = SlicerSync.counterpart(of: slicer, on: page)
                let synced = SlicerSync.isSynced(slicer, on: page)
                HStack(spacing: 0) {
                    HStack(spacing: Design.Space.xs) {
                        Text(page.name).font(Design.Typeface.body).lineLimit(1).truncationMode(.middle)
                        if page.id == store.currentPageID {
                            Text("This page").font(Design.Typeface.caption).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Sync with \(page.name)", isOn: Binding(
                        get: { synced },
                        set: { store.setSlicerSync(slicer.id, pageID: page.id, synced: $0) }))
                        .frame(width: 44)
                    Toggle("Visible on \(page.name)", isOn: Binding(
                        get: { other.map { !$0.isHidden } ?? false },
                        set: { store.setSlicerVisible(slicer.id, pageID: page.id, visible: $0) }))
                        .frame(width: 44)
                }
                .toggleStyle(.checkbox).labelsHidden().controlSize(.small)
                .frame(height: 26)
            }
        }
        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
    }

    // MARK: Advanced

    @ViewBuilder
    private func advanced(_ slicer: VisualSpec) -> some View {
        let grouped = SlicerSync.group(slicer) != nil
        PropertyRow("Group name") {
            TextField(slicer.fields(.field).first?.caption ?? "Group", text: $groupDraft)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .onSubmit { store.renameSyncGroup(of: slicer.id, to: groupDraft) }
        }
        PaneNote("Slicers on the same field that share a group name stay in step. Press Return to apply.")
        Toggle("Sync field changes to other slicers", isOn: Binding(
            get: { SlicerSync.syncsFields(slicer) },
            set: { store.setSyncOption(of: slicer.id, "fieldChanges", $0) }))
            .disabled(!grouped)
        Toggle("Sync filter changes to other slicers", isOn: Binding(
            get: { SlicerSync.syncsFilters(slicer) },
            set: { store.setSyncOption(of: slicer.id, "filterChanges", $0) }))
            .disabled(!grouped)
    }

    // MARK: Groups in the report

    @ViewBuilder
    private func groupList(_ groups: [SlicerSync.Group]) -> some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: Design.Space.s) {
                SectionLabel("Sync groups in this report")
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: Design.Space.xxs) {
                        HStack(spacing: Design.Space.xs) {
                            Text(group.name).font(Design.Typeface.bodyStrong).lineLimit(1)
                            if group.field != group.name, !group.field.isEmpty {
                                Text(group.field).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        ForEach(group.members) { member in
                            Button {
                                store.view = .report
                                store.goToPage(member.page.id)
                                store.selection = [member.visual.id]
                            } label: {
                                HStack(spacing: Design.Space.xs) {
                                    Image(systemName: member.visual.isHidden ? "eye.slash" : "eye")
                                        .font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 14)
                                    Text(member.page.name).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Go to the slicer on \(member.page.name)")
                            .accessibilityLabel("\(member.page.name), \(member.visual.isHidden ? "hidden" : "visible")")
                        }
                    }
                }
            }
            .padding(Design.Space.m)
        }
    }
}
