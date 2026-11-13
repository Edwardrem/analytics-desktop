import SwiftUI
import FacetCore
import FacetDesign
import FacetVisuals

/// Reading view: the page as readers see it, with page and bookmark navigation, visual header tools
/// (drill, focus, spotlight, sort, export, show as table) and, when the report allows it, personalised visuals.
struct PresentationView: View {
    @EnvironmentObject var store: DocumentStore
    var body: some View { ReadingPage(runtime: ReportRuntime.of(store)) }
}

private struct ReadingPage: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var runtime: ReportRuntime
    @State private var showFilters = false

    var body: some View {
        GeometryReader { geo in
            let page = store.currentPage
            let scale = max(0.1, min(geo.size.width / page.size.width, (geo.size.height - 44) / page.size.height))
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ZStack {
                        store.theme.backgroundColor
                        if let c = page.background.color { Color(hex: c).opacity(1 - page.background.transparency / 100) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { runtime.spotlightID = nil; store.clearPointSelections() }
                    ForEach(page.visuals.filter { !$0.isHidden }.sorted { $0.zIndex < $1.zIndex }) { spec in
                        ReadingVisual(runtime: runtime, saved: spec, scale: scale)
                    }
                }
                .frame(width: page.size.width, height: page.size.height, alignment: .topLeading)
                .scaleEffect(scale)
                .frame(width: page.size.width * scale, height: page.size.height * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.92))
                bar(page)
            }
        }
    }

    private func bar(_ page: Page) -> some View {
        HStack(spacing: Design.Space.m) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: []).help("Previous page")
            Text(page.name).font(Design.Typeface.bodyStrong)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: []).help("Next page")
            if !store.report.bookmarks.isEmpty {
                Menu("Bookmarks") {
                    ForEach(store.report.bookmarks) { b in Button(b.name) { store.applyBookmark(b.id) } }
                }.fixedSize()
            }
            if store.report.settings.filterPaneVisibleToReaders {
                Button { showFilters.toggle() } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }
                    .help("Filters on this page")
                    .popover(isPresented: $showFilters, arrowEdge: .top) {
                        ReaderFiltersPanel(runtime: runtime).environmentObject(store)
                    }
            }
            Spacer()
            if runtime.spotlightID != nil {
                Button("End Spotlight") { runtime.spotlightID = nil }
            }
            if runtime.hasPersonalizations(on: page) {
                Button("Reset to Default") { runtime.resetPersonalizations(on: page) }
                    .help("Discard your changes to the visuals on this page")
            }
            Button("Done") { runtime.spotlightID = nil; store.presenting = false }.keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, Design.Space.l).frame(height: 44)
        .background(.bar)
    }

    private func step(_ d: Int) {
        let pages = store.report.pages.filter { !$0.isHidden }
        guard let i = pages.firstIndex(where: { $0.id == store.currentPageID }), let next = pages[safe: i + d] else { return }
        runtime.spotlightID = nil
        store.goToPage(next.id)
    }
}

/// One visual in the reading view, with its hover header.
private struct ReadingVisual: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var runtime: ReportRuntime
    let saved: VisualSpec
    let scale: Double
    @State private var hovering = false
    @State private var personalizing = false

    var body: some View {
        let spec = runtime.effectiveSpec(saved)
        let dimmed = runtime.spotlightID != nil && runtime.spotlightID != saved.id
        ZStack(alignment: .topTrailing) {
            VisualView(spec: spec, data: runtime.data(for: saved), context: context(for: spec))
                .frame(width: saved.frame.width, height: saved.frame.height)
                .rotationEffect(.degrees(saved.frame.rotation))
            if (hovering || personalizing), !saved.type.isPageElement, !store.report.settings.hideVisualHeaders {
                header(spec).offset(y: -26 / scale)
            }
        }
        .frame(width: saved.frame.width, height: saved.frame.height, alignment: .topTrailing)
        .offset(x: saved.frame.x, y: saved.frame.y)
        .opacity(dimmed ? 0.18 : 1)
        .animation(Design.Motion.quick, value: dimmed)
        .onHover { hovering = $0 }
        .zIndex(Double(saved.zIndex) + (hovering || personalizing ? 0.5 : 0))
    }

    /// The store's context, except that a personalised visual never writes its reader-only shape back to the document.
    private func context(for spec: VisualSpec) -> VisualContext {
        var c = store.context(for: spec)
        guard runtime.personalization(for: saved.id) != nil else { return c }
        let id = saved.id
        c.onSpecChange = { [weak store] new in
            // Expansion state is a view of the data, not a change of shape: keep it; drop the rest.
            store?.updateVisual(id, name: "Expand", coalesce: "spec-\(id)", invalidates: .layout) {
                $0.expandedPaths = new.expandedPaths
                $0.expandedAllLevels = new.expandedAllLevels
            }
        }
        return c
    }

    private func header(_ spec: VisualSpec) -> some View {
        let levels = TooltipActions.drillLevels(spec)
        let settings = store.report.settings
        return HStack(spacing: 2) {
            if levels > 1 {
                IconButton("arrow.up", help: "Drill up") { store.drill(.up, in: saved.id) }.disabled(spec.drillLevel == 0)
                IconButton("arrow.down.to.line", help: "Go to the next level") { store.drill(.down(nil), in: saved.id) }
                    .disabled(spec.drillLevel >= levels - 1)
                IconButton("arrow.triangle.branch", help: "Expand all down one level") { store.drill(.expandAll, in: saved.id) }
                    .disabled(spec.drillLevel >= levels - 1)
            }
            IconButton("arrow.up.left.and.arrow.down.right", help: "Focus mode") { store.focusVisualID = saved.id }
            if settings.allowPersonalizeVisuals, Personalize.canPersonalize(saved.type) {
                IconButton("slider.horizontal.3", help: "Personalize this visual", isOn: runtime.personalization(for: saved.id) != nil) {
                    personalizing.toggle()
                }
                .popover(isPresented: $personalizing, arrowEdge: .bottom) {
                    PersonalizePanel(runtime: runtime, saved: saved).environmentObject(store)
                }
            }
            Menu {
                Button("Show as a Table") { store.showAsTableID = saved.id }
                Button(runtime.spotlightID == saved.id ? "End Spotlight" : "Spotlight") {
                    runtime.spotlightID = runtime.spotlightID == saved.id ? nil : saved.id
                }
                SortMenu(fields: spec.allFields, current: spec.sort) { field, descending in
                    runtime.setPersonalization(Personalize.settingSort(runtime.personalization(for: saved.id), field: field, descending: descending),
                                               for: saved.id)
                }
                if settings.allowExportData != "none" {
                    Menu("Export Data") {
                        ForEach(["csv", "xlsx", "json"], id: \.self) { format in
                            Button(format == "xlsx" ? "Excel…" : "\(format.uppercased())…") {
                                VisualExport.export(runtime.data(for: saved), named: saved.name, store: store, format: format)
                            }
                        }
                    }
                }
                Button("Copy Visual as Image") { VisualExport.copyImage(of: spec, store: store) }
                if runtime.personalization(for: saved.id) != nil {
                    Divider()
                    Button("Reset This Visual") { runtime.setPersonalization(nil, for: saved.id) }
                }
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

/// "Sort by" for a visual: its fields, and the direction.
struct SortMenu: View {
    let fields: [FieldRef]
    let current: [SortSpec]
    let onChoose: (_ field: FieldRef?, _ descending: Bool) -> Void

    var body: some View {
        var seen = Set<String>()
        let choices = fields.filter { seen.insert($0.key).inserted }
        let active = current.first
        Menu("Sort By") {
            ForEach(choices) { f in
                Button { onChoose(f, active?.field.key == f.key ? !(active?.descending ?? true) : f.isAggregate) } label: {
                    if active?.field.key == f.key {
                        Label(f.caption, systemImage: active?.descending == true ? "arrow.down" : "arrow.up")
                    } else { Text(f.caption) }
                }
            }
            if let active {
                Divider()
                Button("Sort Ascending") { onChoose(active.field, false) }.disabled(!active.descending)
                Button("Sort Descending") { onChoose(active.field, true) }.disabled(active.descending)
                Button("Default Order") { onChoose(nil, false) }
            }
        }
        .disabled(choices.isEmpty)
    }
}

/// The reader's controls for one visual: its type and the fields in each well.
private struct PersonalizePanel: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var runtime: ReportRuntime
    let saved: VisualSpec

    private var current: Personalization? { runtime.personalization(for: saved.id) }
    private func aggregation(_ f: FieldRef) -> Aggregation { store.defaultAggregation(for: f) }

    var body: some View {
        let spec = runtime.effectiveSpec(saved)
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack {
                Text("Personalize").font(Design.Typeface.headline)
                Spacer(minLength: Design.Space.m)
                Button("Reset") { runtime.setPersonalization(nil, for: saved.id) }
                    .controlSize(.small).disabled(current == nil).help("Show the visual as its author saved it")
            }
            SectionLabel("Visualization type")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: Design.Space.xs), count: 6), spacing: Design.Space.xs) {
                ForEach(Personalize.offeredTypes, id: \.self) { type in
                    IconButton(VisualCatalog.symbol(for: type), help: type.displayName, isOn: spec.type == type) {
                        runtime.setPersonalization(Personalize.settingType(current, type, saved: saved, aggregation: aggregation), for: saved.id)
                    }
                }
            }
            ForEach(spec.type.wells.filter { $0 != .tooltips }, id: \.self) { well in
                wellEditor(well, spec.fields(well))
            }
            PaneNote("Your changes are yours alone: the report itself is not edited.")
        }
        .padding(Design.Space.m)
        .frame(width: 280)
    }

    @ViewBuilder private func wellEditor(_ well: Well, _ fields: [FieldRef]) -> some View {
        SectionLabel(well.displayName).padding(.top, Design.Space.xs)
        ForEach(fields) { field in
            HStack(spacing: Design.Space.xs) {
                Text(field.caption).font(Design.Typeface.body).lineLimit(1)
                Spacer(minLength: 0)
                IconButton("xmark", help: "Remove \(field.caption)") { set(well, fields.filter { $0.id != field.id }) }
            }
        }
        FieldPickerButton(selection: nil, placeholder: "Add a field", allowsMeasures: !well.isGrouping, allowsClear: false) { picked in
            guard var field = picked else { return }
            field.id = UUID()
            if !well.isGrouping, field.kind == .column, runtime.effectiveSpec(saved).type != .table {
                field.aggregation = aggregation(field)
            }
            set(well, fields + [field])
        }
    }

    private func set(_ well: Well, _ fields: [FieldRef]) {
        runtime.setPersonalization(Personalize.settingFields(current, well: well, fields: fields, saved: saved, aggregation: aggregation),
                                   for: saved.id)
    }
}

/// The rows behind a data point ("See records"), or the point itself as a table when the visual shows only measures.
struct RecordsSheet: View {
    @EnvironmentObject var store: DocumentStore
    let title: String
    let note: String
    let spec: VisualSpec
    let request: VisualRequest
    let exportable: Bool
    @State private var data: VisualData?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack {
                Text(title).font(Design.Typeface.headline).lineLimit(1)
                Spacer()
                if exportable, let data, !data.isEmpty {
                    Button("Export CSV…") { VisualExport.export(data, named: title, store: store, format: "csv") }
                }
                Button("Done") { store.dismissSheet() }.keyboardShortcut(.defaultAction)
            }
            if let data {
                VisualView(spec: spec, data: data, context: store.context(for: spec, interactive: false))
                Text(data.table.rowCount >= SeeRecords.rowLimit ? "\(note) Showing the first \(SeeRecords.rowLimit.formatted()) lines." : note)
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(Design.Space.l)
        .frame(width: 860, height: 560)
        .task {
            let spec = spec, request = request
            data = await store.withEngine { $0.visualData(spec: spec, request: request) }
        }
    }
}

extension DocumentStore {
    /// "See records" for a data point of a visual.
    func showRecords(for visualID: UUID, point: DataPointSelection) {
        guard let visual = currentPage.visual(visualID) else { return }
        let request = SeeRecords.request(source: request(for: visual, on: currentPage), point: point)
        let label = point.values.map { ValueFormatter.format($0) }.joined(separator: ", ")
        let allowed = report.settings.allowExportData
        if let records = SeeRecords.recordsSpec(for: visual, model: model) {
            let table = records.fields(.values).first?.table ?? ""
            present {
                RecordsSheet(title: "Records for \(label)", note: "Rows of \(table) behind this data point. Identical rows are combined; Rows shows how many.",
                             spec: records, request: request, exportable: allowed == "underlying")
            }
        } else {
            present {
                RecordsSheet(title: "Data point \(label)", note: "This visual shows measures only, so the data point is shown instead of underlying records.",
                             spec: SeeRecords.pointSpec(for: visual), request: request, exportable: allowed != "none")
            }
        }
    }
}
