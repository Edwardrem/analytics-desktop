import SwiftUI
import FacetCore
import FacetDesign
import FacetVisuals

/// The visual header's author options (`format["visualHeader"]`): whether readers see it, and an
/// information icon with the author's help text.
enum VisualHeaderOptions {
    static let card = "visualHeader"
    /// The author's help text, when there is any.
    static func helpText(_ spec: VisualSpec) -> String? {
        let text = spec.fmtString(card, "helpText", "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    /// Readers see the header unless the report hides every header or this visual hides its own.
    static func showsToReaders(_ spec: VisualSpec, settings: ReportSettings) -> Bool {
        !spec.type.isPageElement && !settings.hideVisualHeaders && spec.fmtBool(card, "show", true)
    }
}

/// The information icon of a visual header: the author's help text on hover.
struct VisualHelpIcon: View {
    let text: String
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(width: 22, height: 22).contentShape(Rectangle())
            .help(text).accessibilityLabel("Help").accessibilityValue(text)
    }
}

/// The quiet strip above a visual: a grip to move it, drill controls, focus and more.
struct VisualHeader: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    let scale: Double
    let moveGesture: AnyGesture<Void>

    var body: some View {
        let levels = spec.fields(.category).count
        HStack(spacing: 2) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 26, height: 22).contentShape(Rectangle())
                .gesture(moveGesture).help("Drag to move")
            if levels > 1 {
                IconButton("arrow.up", help: "Drill up") { store.drill(.up, in: spec.id) }.disabled(spec.drillLevel == 0)
                IconButton("arrow.down.to.line", help: "Go to the next level") { store.drill(.down(nil), in: spec.id) }
                    .disabled(spec.drillLevel >= levels - 1)
                IconButton("arrow.triangle.branch", help: "Expand all down one level") { store.drill(.expandAll, in: spec.id) }
                    .disabled(spec.drillLevel >= levels - 1)
            }
            if let help = VisualHeaderOptions.helpText(spec) { VisualHelpIcon(text: help) }
            if !spec.type.isPageElement {
                if !(store.filters(for: spec, on: store.currentPage).isEmpty) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).help("Filters affect this visual")
                }
                IconButton("arrow.up.left.and.arrow.down.right", help: "Focus mode") { store.focusVisualID = spec.id }
            }
            if let accessory = Features.visualHeaderAccessory?(spec, store) { accessory }
            Menu {
                VisualContextMenu(spec: spec)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 22)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More options")
        }
        .padding(.horizontal, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Design.Palette.hairline))
        .scaleEffect(1 / scale, anchor: .bottomTrailing)
    }
}

@MainActor
enum InteractionRules {
    /// A selection can highlight a visual that draws highlights, unless it comes from a slicer (slicers only filter).
    static func canHighlight(from source: VisualSpec?, to target: VisualSpec) -> Bool {
        DocumentStore.highlightable.contains(target.type) && source?.type.isSlicer != true
    }
    /// Edit interactions applies to visuals that show data.
    static func canEdit(_ spec: VisualSpec?) -> Bool { spec.map { !$0.type.isPageElement } ?? false }
}

/// Filter / highlight / none chooser shown on every other data visual while editing interactions.
struct InteractionPicker: View {
    @EnvironmentObject var store: DocumentStore
    let source: UUID
    let target: VisualSpec

    var body: some View {
        let page = store.currentPage
        let current = store.interaction(from: source, to: target, on: page)
        HStack(spacing: 2) {
            button(.filter, "line.3.horizontal.decrease.circle", "Filter", current)
            if InteractionRules.canHighlight(from: page.visual(source), to: target) {
                button(.highlight, "chart.bar.fill", "Highlight", current)
            }
            button(.none, "nosign", "None", current)
        }
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    private func button(_ mode: InteractionMode, _ symbol: String, _ help: String, _ current: InteractionMode) -> some View {
        IconButton(symbol, help: help, isOn: current == mode) {
            store.updatePage(name: "Edit Interactions", invalidates: .visuals(nil)) { p in
                var m = p.interactions[source] ?? [:]
                m[target.id] = mode
                p.interactions[source] = m
            }
        }
    }
}

struct VisualContextMenu: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec

    var body: some View {
        if store.mobileLayout {
            Button("Remove from Mobile Layout") { ensureSelected(); store.removeFromMobileLayout(Array(store.selection)) }
            Button("Reset Mobile Formatting") { store.resetMobileFormat(spec.id) }.disabled(spec.mobileFormat == nil)
            Divider()
        }
        Button("Copy") { ensureSelected(); store.copySelection() }
        Button("Cut") { ensureSelected(); store.cutSelection() }
        Button("Duplicate") { ensureSelected(); store.duplicateSelection() }
        Button("Delete", role: .destructive) { ensureSelected(); store.deleteSelection() }
        Divider()
        if !spec.type.isPageElement {
            Button("Focus Mode") { store.focusVisualID = spec.id }
            Button("Show as a Table") { store.showAsTableID = spec.id }
            Button("Copy Visual as Image") { VisualExport.copyImage(of: spec, store: store) }
            Menu("Export Data") {
                Button("CSV…") { VisualExport.exportData(of: spec, store: store, format: "csv") }
                Button("Excel…") { VisualExport.exportData(of: spec, store: store, format: "xlsx") }
                Button("JSON…") { VisualExport.exportData(of: spec, store: store, format: "json") }
            }
            Button(ReportRuntime.of(store).spotlightID == spec.id ? "End Spotlight" : "Spotlight") {
                let runtime = ReportRuntime.of(store)
                runtime.spotlightID = runtime.spotlightID == spec.id ? nil : spec.id
            }
            SortMenu(fields: spec.allFields, current: spec.sort) { field, descending in
                store.updateVisual(spec.id, name: "Sort") { $0.sort = field.map { [SortSpec(field: $0, descending: descending)] } ?? [] }
            }
            Button(store.editInteractionsFor == spec.id ? "Done Editing Interactions" : "Edit Interactions") {
                store.editInteractionsFor = store.editInteractionsFor == spec.id ? nil : spec.id
            }
            if ClusterFields.plan(spec: spec, model: store.model) != nil {
                Button("Automatically Find Clusters…") { store.findClusters(in: spec.id) }
            }
            Divider()
        }
        Button("Format Painter") { store.formatPainterSource = spec.id }
        Menu("Arrange") {
            Button("Bring to Front") { ensureSelected(); store.reorder(.front) }
            Button("Bring Forward") { ensureSelected(); store.reorder(.forward) }
            Button("Send Backward") { ensureSelected(); store.reorder(.backward) }
            Button("Send to Back") { ensureSelected(); store.reorder(.back) }
        }
        if store.selection.count > 1 { Button("Group") { store.groupSelection() } }
        if spec.groupID != nil { Button("Ungroup") { ensureSelected(); store.ungroupSelection() } }
        Button(spec.isLocked ? "Unlock" : "Lock") {
            store.updateVisual(spec.id, name: "Lock", invalidates: .layout) { $0.isLocked.toggle() }
        }
        Button("Hide") { store.updateVisual(spec.id, name: "Hide Visual", invalidates: .layout) { $0.isHidden = true } }
    }
    private func ensureSelected() {
        if !store.selection.contains(spec.id) { store.selection = store.withGroupMembers([spec.id]) }
    }
}

/// Shown on an empty page: what to do first, said once, quietly.
struct StartSurface: View {
    @EnvironmentObject var store: DocumentStore
    var body: some View {
        let hasData = !store.model.tables.isEmpty
        VStack(spacing: Design.Space.l) {
            Image(systemName: hasData ? "square.grid.2x2" : "cylinder.split.1x2")
                .font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.tertiary)
            Text(hasData ? "Build a visual" : "Add data to begin")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(store.theme.foregroundColor)
            Text(hasData ? "Drag a field here, or choose a visual from the toolbar."
                         : "Connect to a file, a database, or your Microsoft account.")
                .font(Design.Typeface.body).foregroundStyle(store.theme.secondaryColor)
            if !hasData {
                HStack(spacing: Design.Space.m) {
                    Button("Get Data…") { AppCommands.run("data.get", store) }.buttonStyle(.borderedProminent)
                    Button("Try Sample Data") { AppCommands.run("data.sample", store) }
                    Button("Open…") { AppCommands.run("file.open", store) }
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
