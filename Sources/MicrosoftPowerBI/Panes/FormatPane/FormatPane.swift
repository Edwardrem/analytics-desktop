import SwiftUI
import FacetCore
import FacetDesign
import FacetVisuals

/// The Format pane (`InspectorPane.format`). With one or more visuals selected it shows Visual and
/// General tabs whose cards are generated from the FacetVisuals format catalogs, with search,
/// expand/collapse and per-card reset; several visuals share the cards they have in common. With
/// nothing selected it shows page and report-level formatting.
struct FormatPane: View {
    enum ScopeTab: Hashable { case page, report }

    @EnvironmentObject var store: DocumentStore
    @State private var visualTab: FormatCatalog.Tab = .visual
    @State private var scopeTab: ScopeTab = .page
    @State private var query = ""
    /// Card ids the reader collapsed (all cards start expanded, as in Power BI).
    @State private var collapsed: Set<String> = []
    /// Cards collapsed while a search is showing (results start expanded).
    @State private var collapsedInSearch: Set<String> = []
    /// On-object formatting asks for a card through this; the pane opens it and scrolls to it.
    @ObservedObject private var focus = FormatFocus.shared
    @State private var scrollTarget: String?

    var body: some View {
        let specs = store.selectedVisuals
        VStack(spacing: 0) {
            if specs.isEmpty { scopePane } else { visualPane(specs) }
        }
        .onChange(of: query) { _, _ in collapsedInSearch.removeAll() }
        .onChange(of: focus.request) { _, _ in takeFocusRequest() }
        .onAppear(perform: takeFocusRequest)
    }

    private func takeFocusRequest() {
        guard let request = focus.request, request.store == ObjectIdentifier(store) else { return }
        focus.request = nil
        visualTab = request.tab
        query = ""
        collapsed.remove(request.card)
        scrollTarget = request.card
    }

    // MARK: - Visuals are selected

    private func visualPane(_ specs: [VisualSpec]) -> some View {
        let all = FormatCatalog.cards(for: specs, tab: visualTab)
        let list = FormatCatalog.filter(all, query: query)
        let ids = specs.map(\.id)
        return VStack(spacing: 0) {
            PaneHeader(title: "Format", detail: specs.count == 1 ? (specs.first?.name ?? "") : "\(specs.count) visuals") {
                IconButton("rectangle.expand.vertical", help: "Expand all cards") { setCollapsed([]) }
                IconButton("rectangle.compress.vertical", help: "Collapse all cards") { setCollapsed(Set(list.map(\.id))) }
            }
            Hairline()
            Picker("Format tab", selection: $visualTab) {
                Text("Visual").tag(FormatCatalog.Tab.visual)
                Text("General").tag(FormatCatalog.Tab.general)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.xs)
            searchBar
            if list.isEmpty {
                EmptyState(systemImage: "slider.horizontal.3", title: "No formatting options",
                           message: emptyMessage(selectionCount: specs.count, hasCards: !all.isEmpty))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(list) { card in
                                PaneSection(title: card.label, expanded: expansion(card.id)) {
                                    rows(card, specs: specs, ids: ids)
                                }
                                .id(card.id)
                            }
                        }
                    }
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        // After this update, so the requested tab's cards are laid out.
                        DispatchQueue.main.async {
                            withAnimation(Design.Motion.quick) { proxy.scrollTo(target, anchor: .top) }
                            scrollTarget = nil
                        }
                    }
                }
                // Rows belong to the visuals they were built for: a new selection gets new rows,
                // so an edit still being typed can only ever reach the visuals it was typed for.
                .id(ids)
            }
        }
    }

    @ViewBuilder private func rows(_ card: FormatCardModel, specs: [VisualSpec], ids: [UUID]) -> some View {
        switch card.role {
        case .format:
            ForEach(card.properties) { property in
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                    FormatPropertyRow(property: property, specs: specs, theme: store.theme) { p, value in
                        write(ids, p, value)
                    }
                    if specs.count == 1, let spec = specs.first {
                        if let target = FormatCatalog.fxTarget(of: property, type: spec.type) {
                            FormatFxButton(visualID: spec.id, target: target)
                        } else if let kind = FormatBindings.kind(of: property) {
                            FormatBindingButton(visualID: spec.id, card: property.card, key: property.key,
                                                name: FormatBindingButton.name(of: property), kind: kind)
                        }
                    }
                }
            }
            resetButton(card, enabled: specs.contains { FormatCatalog.isOverridden(card, in: $0) }) { resetCard(ids, card) }
        case .position:
            if let spec = specs.first {
                FormatPositionRows(properties: card.properties, frame: store.frame(of: spec)) { key, value in
                    writePosition(spec.id, key, value)
                }
            }
        case .tooltip:
            if let spec = specs.first {
                FormatTooltipRows(spec: spec) { page in
                    store.updateVisuals([spec.id], name: "Tooltip Page") { $0.tooltipPageID = page }
                }
                resetButton(card, enabled: spec.tooltipPageID != nil) {
                    store.updateVisuals([spec.id], name: "Reset Tooltip") { $0.tooltipPageID = nil }
                }
            }
        case .presets:
            FormatPresetRows(specs: specs, theme: store.theme) { name in applyPreset(ids, name) }
        case .conditional:
            if let spec = specs.first { FormatConditionalRows(properties: card.properties, spec: spec) }
        case .altText:
            if let spec = specs.first {
                FormatAltTextRows(visualID: spec.id, altText: spec.altText) { writeAltText(spec.id, $0) }
                resetButton(card, enabled: !spec.altText.isEmpty) { writeAltText(spec.id, "") }
            }
        case .action:
            if let spec = specs.first {
                FormatActionTooltipRows(visualID: spec.id, tooltip: spec.action?.tooltip ?? "") { writeActionTooltip(spec.id, $0) }
                resetButton(card, enabled: FormatCatalog.isOverridden(card, in: spec)) { writeActionTooltip(spec.id, "") }
            }
        }
    }

    private func resetButton(_ card: FormatCardModel, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button("Reset to default", action: action)
            .buttonStyle(.link).font(Design.Typeface.caption)
            .disabled(!enabled)
            .help(enabled ? "Reset every \(card.label) setting to its default" : "\(card.label) already uses its defaults")
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func emptyMessage(selectionCount: Int, hasCards: Bool) -> String {
        if hasCards { return "Nothing matches “\(query)”." }
        if selectionCount > 1 { return "The selected visuals have no \(visualTab == .visual ? "visual" : "general") settings in common." }
        return "This visual has no type-specific settings. Use the General tab."
    }

    /// Search results start expanded and collapse independently of the browsing state.
    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { query.isEmpty ? !collapsed.contains(id) : !collapsedInSearch.contains(id) },
                set: { on in
                    if query.isEmpty { if on { collapsed.remove(id) } else { collapsed.insert(id) } }
                    else if on { collapsedInSearch.remove(id) } else { collapsedInSearch.insert(id) }
                })
    }

    private func setCollapsed(_ ids: Set<String>) {
        if query.isEmpty { collapsed = ids } else { collapsedInSearch = ids }
    }

    // MARK: - Nothing is selected: page and report formatting

    private var scopePane: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Format", detail: scopeTab == .page ? store.currentPage.name : "All pages") {}
            Hairline()
            Picker("Format scope", selection: $scopeTab) {
                Text("Page").tag(ScopeTab.page)
                Text("Report").tag(ScopeTab.report)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.xs)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch scopeTab {
                    case .page: PageSettingsView()
                    case .report: ReportSettingsView()
                    }
                }
                .padding(Design.Space.m)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(Design.Typeface.caption)
                .foregroundStyle(.tertiary)
            TextField("Search formatting", text: $query)
                .textFieldStyle(.plain)
                .controlSize(.small)
                .accessibilityLabel("Search formatting")
            if !query.isEmpty {
                IconButton("xmark.circle.fill", help: "Clear search") { query = "" }
            }
        }
        .padding(.horizontal, Design.Space.m)
        .padding(.bottom, Design.Space.xs)
    }

    // MARK: - Writes (the only path into the document; each is one undo step)

    /// One format key on every target visual. Appearance only, so no requery.
    private func write(_ ids: [UUID], _ property: FormatProperty, _ value: JSONValue?) {
        let stored = FormatCatalog.stored(value, for: property)
        store.updateVisuals(ids, name: "Format \(property.cardLabel)", coalesce: "fmt-\(Self.key(ids))-\(property.id)") {
            $0.setFmt(property.card, property.key, stored)
        }
    }

    /// Resets every key of one card to its renderer default.
    private func resetCard(_ ids: [UUID], _ card: FormatCardModel) {
        store.updateVisuals(ids, name: "Reset \(card.label)") { spec in
            for key in card.resetKeys { spec.setFmt(card.card, key, nil) }
        }
    }

    /// Merges a style preset into every target visual (preset keys win; other keys are kept).
    private func applyPreset(_ ids: [UUID], _ name: String) {
        let theme = store.theme
        store.updateVisuals(ids, name: "Apply Style Preset") { $0 = FormatPresets.applying(name, to: $0, theme: theme) }
    }

    /// Position, size and rotation live on the frame of the layout being edited.
    private func writePosition(_ id: UUID, _ key: String, _ value: Double?) {
        guard let spec = store.visual(id), let frame = FormatCatalog.frame(store.frame(of: spec), setting: key, to: value) else { return }
        store.setFrames([id: frame], name: key == "x" || key == "y" ? "Move Visual" : "Transform Visual",
                        coalesce: "pos-\(id.uuidString)-\(key)")
    }

    private func writeAltText(_ id: UUID, _ text: String) {
        store.updateVisuals([id], name: "Change Alt Text") { $0.altText = text }
    }

    /// The tooltip shown on hover; a visual with no action yet gets one that does nothing else.
    private func writeActionTooltip(_ id: UUID, _ text: String) {
        store.updateVisuals([id], name: "Change Tooltip") { spec in
            if spec.action == nil, text.isEmpty { return }
            var action = spec.action ?? ActionSpec()
            action.tooltip = text
            spec.action = action == ActionSpec() ? nil : action
        }
    }

    private static func key(_ ids: [UUID]) -> String { ids.map(\.uuidString).joined(separator: "+") }
}

extension DocumentStore {
    /// Applies an appearance change to several visuals as one undo step (`.layout`: no requery).
    func updateVisuals(_ ids: [UUID], name: String, coalesce: String? = nil, _ body: (inout VisualSpec) -> Void) {
        let targets = Set(ids)
        guard !targets.isEmpty else { return }
        mutate(name, coalesce: coalesce, invalidates: .layout) { d in
            for p in d.report.pages.indices {
                for i in d.report.pages[p].visuals.indices where targets.contains(d.report.pages[p].visuals[i].id) {
                    body(&d.report.pages[p].visuals[i])
                }
            }
        }
    }
}
