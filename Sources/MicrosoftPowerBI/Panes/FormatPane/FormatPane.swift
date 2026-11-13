import SwiftUI
import FacetCore
import FacetDesign

/// The Format pane (`InspectorPane.format`). With a visual selected it shows Visual and General
/// tabs whose cards are generated from the FacetVisuals format catalogs (`ComponentFormatCatalog`
/// for components, the chart entries in `ChartFormatProperties` for charts), with search,
/// expand/collapse cards and per-card reset to default. With nothing selected it shows page and
/// report-level formatting.
struct FormatPane: View {
    enum VisualTab: Hashable { case visual, general }
    enum ScopeTab: Hashable { case page, report }

    @EnvironmentObject var store: DocumentStore
    @State private var visualTab: VisualTab = .visual
    @State private var scopeTab: ScopeTab = .page
    @State private var query = ""
    /// Card ids the reader collapsed (all cards start expanded, as in Power BI).
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if let spec = store.selectedVisual {
                visualPane(spec)
            } else {
                scopePane
            }
        }
    }

    // MARK: - A visual is selected

    private func visualPane(_ spec: VisualSpec) -> some View {
        let list = cards(for: spec)
        return VStack(spacing: 0) {
            PaneHeader(title: "Format", detail: spec.name) {
                IconButton("rectangle.expand.vertical", help: "Expand all cards") { collapsed.removeAll() }
                IconButton("rectangle.compress.vertical", help: "Collapse all cards") { collapsed.formUnion(list.map(\.id)) }
            }
            Hairline()
            Picker("Format tab", selection: $visualTab) {
                Text("Visual").tag(VisualTab.visual)
                Text("General").tag(VisualTab.general)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.xs)
            searchBar
            if list.isEmpty {
                EmptyState(systemImage: "slider.horizontal.3", title: "No formatting options",
                           message: query.isEmpty
                               ? "This visual has no \(visualTab == .visual ? "type-specific" : "") format settings. Use the General tab."
                               : "Nothing matches “\(query)”.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if visualTab == .general {
                            FormatPositionCard(frame: spec.frame, move: writePosition)
                            ForEach(list) { card in
                                FormatCardView(card: card, spec: spec, theme: store.theme,
                                               expanded: expansion(card.id), write: write) {
                                    resetCard(card)
                                }
                            }
                            FormatAltTextCard(altText: spec.altText, commit: writeAltText)
                        } else {
                            ForEach(list) { card in
                                FormatCardView(card: card, spec: spec, theme: store.theme,
                                               expanded: expansion(card.id), write: write) {
                                    resetCard(card)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func cards(for spec: VisualSpec) -> [FormatCardModel] {
        switch visualTab {
        case .visual:
            return FormatCatalog.filter(FormatCatalog.visualCards(for: spec.type), query: query)
        case .general:
            return FormatCatalog.filter(FormatCatalog.generalCards(for: spec.type), query: query)
        }
    }

    /// Cards match the search expand regardless of the collapsed set, so results are visible.
    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { query.isEmpty ? !collapsed.contains(id) : true },
                set: { on in
                    guard query.isEmpty else { return }
                    if on { collapsed.remove(id) } else { collapsed.insert(id) }
                })
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
                .font(.system(size: 11))
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

    // MARK: - Writes (the only path into the document)

    /// One format key, through `updateVisual` with `.layout` invalidation — appearance only, no requery.
    private func write(_ property: FormatPropertyModel, _ value: JSONValue?) {
        guard let id = store.selectedVisual?.id else { return }
        store.updateVisual(id, name: "Format \(property.cardLabel)",
                           coalesce: "fmt-\(id.uuidString)-\(property.id)", invalidates: .layout) {
            $0.setFmt(property.card, property.key, value)
        }
    }

    /// Resets every key of one card to its renderer default.
    private func resetCard(_ card: FormatCardModel) {
        guard let id = store.selectedVisual?.id else { return }
        store.updateVisual(id, name: "Reset \(card.label)", invalidates: .layout) { spec in
            for p in card.properties { spec.setFmt(card.card, p.key, nil) }
        }
    }

    /// Position/size/rotation live on the frame, not in the format bag.
    private func writePosition(_ key: String, _ value: Double) {
        guard let spec = store.selectedVisual else { return }
        var f = spec.frame
        switch key {
        case "x": f.x = value
        case "y": f.y = value
        case "width": f.width = value
        case "height": f.height = value
        case "rotation": f.rotation = value
        default: return
        }
        store.setFrames([spec.id: f],
                        name: key == "x" || key == "y" ? "Move Visual" : "Transform Visual",
                        coalesce: "pos-\(spec.id.uuidString)-\(key)")
    }

    private func writeAltText(_ text: String) {
        guard let id = store.selectedVisual?.id else { return }
        store.updateVisual(id, name: "Change Alt Text", invalidates: .layout) { $0.altText = text }
    }
}
