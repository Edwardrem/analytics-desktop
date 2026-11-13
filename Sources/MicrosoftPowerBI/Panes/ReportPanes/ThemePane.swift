import SwiftUI
import FacetCore
import FacetDesign

/// Theme gallery and editor, plus the current page's settings and the report's settings.
struct ThemePane: View {
    enum Section: String, Hashable { case themes, customize, page, report }

    @EnvironmentObject var store: DocumentStore
    @ObservedObject var runtime: ReportPaneRuntime
    @State private var expanded: Set<Section> = [.themes]

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Theme", detail: store.theme.name) {
                IconButton("square.and.arrow.down", help: "Import theme…") { ThemeIO.runImport(store) }
                IconButton("square.and.arrow.up", help: "Export theme…") { ThemeIO.runExport(store) }
                IconButton("arrow.counterclockwise", help: "Reset to the default theme") {
                    store.mutate("Reset Theme", invalidates: .layout) { $0.report.theme = .facet }
                }
                .disabled(store.theme == .facet)
            }
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        PaneSection(title: "Themes", expanded: binding(.themes)) { ThemeGallery() }
                            .id(Section.themes)
                        PaneSection(title: "Customize current theme", expanded: binding(.customize)) { ThemeEditor() }
                            .id(Section.customize)
                        PaneSection(title: "Page", expanded: binding(.page)) { PageSettingsView() }
                            .id(Section.page)
                        PaneSection(title: "Report settings", expanded: binding(.report)) { ReportSettingsView() }
                            .id(Section.report)
                    }
                }
                .onAppear { focus(proxy) }
                .onChange(of: runtime.themeFocus) { _, _ in focus(proxy) }
            }
        }
    }

    private func binding(_ section: Section) -> Binding<Bool> {
        Binding(get: { expanded.contains(section) },
                set: { if $0 { expanded.insert(section) } else { expanded.remove(section) } })
    }

    /// Open and scroll to the section a command asked for.
    private func focus(_ proxy: ScrollViewProxy) {
        guard let target = runtime.themeFocus else { return }
        let section: Section = target == .page ? .page : .report
        runtime.themeFocus = nil
        // Collapse the long sections above so the requested one starts at the top.
        expanded = [section]
        DispatchQueue.main.async {
            withAnimation(Design.Motion.standard) { proxy.scrollTo(section, anchor: .top) }
        }
    }
}

// MARK: - Gallery

struct ThemeGallery: View {
    @EnvironmentObject var store: DocumentStore
    private let columns = [GridItem(.flexible(), spacing: Design.Space.s), GridItem(.flexible(), spacing: Design.Space.s)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Design.Space.s) {
            ForEach(ThemeSpec.builtIn, id: \.name) { theme in
                ThemeCard(theme: theme, isCurrent: store.theme == theme) {
                    store.mutate("Change Theme", invalidates: .layout) { $0.report.theme = theme }
                }
            }
        }
        if !ThemeSpec.builtIn.contains(store.theme) {
            PaneNote("“\(store.theme.name)” is a custom theme. Choosing a built-in theme replaces it; Undo brings it back.")
        }
    }
}

/// Swatch card: a tiny chart in the theme's colours, its palette, and its name.
struct ThemeCard: View {
    let theme: ThemeSpec
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false
    private static let bars: [CGFloat] = [0.55, 0.85, 0.4, 1, 0.7, 0.5]

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Design.Space.s) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(Self.bars.enumerated()), id: \.offset) { i, h in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(theme.dataColor(i))
                            .frame(height: 30 * h)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 30, alignment: .bottom)
                HStack(spacing: 3) {
                    ForEach(0..<8, id: \.self) { i in
                        Circle().fill(theme.dataColor(i)).frame(width: 7, height: 7)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: Design.Space.xs) {
                    Text(theme.name).font(Design.Typeface.caption).foregroundStyle(theme.foregroundColor).lineLimit(1)
                    Spacer(minLength: 0)
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(theme.accentColor)
                    }
                }
            }
            .padding(Design.Space.s)
            .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(theme.backgroundColor))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor : (hovering ? Design.Palette.hairlineStrong : Design.Palette.hairline),
                              lineWidth: isCurrent ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Apply the \(theme.name) theme")
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}

// MARK: - Report settings

struct ReportSettingsView: View {
    @EnvironmentObject var store: DocumentStore
    private static let languages = ["en-US", "en-GB", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "pt-PT", "nl-NL", "sv-SE",
                                    "da-DK", "nb-NO", "fi-FI", "pl-PL", "tr-TR", "ar-SA", "he-IL", "hi-IN", "ja-JP", "ko-KR",
                                    "zh-CN", "zh-TW", "sw-KE", "zu-ZA", "af-ZA"]

    var body: some View {
        let s = store.report.settings
        Group {
            SectionLabel("Interactions")
            PropertyRow("Selecting data") {
                Picker("Default visual interaction", selection: bind(\.defaultInteraction, requery: true)) {
                    Text("Highlights other visuals").tag(InteractionMode.highlight)
                    Text("Filters other visuals").tag(InteractionMode.filter)
                }
                .labelsHidden()
            }
            Toggle("Modern visual tooltips", isOn: bind(\.modernTooltips))
            Toggle("Allow drillthrough from other reports", isOn: bind(\.crossReportDrillthrough))
        }
        Group {
            SectionLabel("Filtering").padding(.top, Design.Space.xs)
            Toggle("Remember each reader's filters", isOn: bind(\.persistentFilters))
            Toggle("Readers can change filter types", isOn: bind(\.allowChangeFilterTypes))
            Toggle("Show the Filters pane to readers", isOn: bind(\.filterPaneVisibleToReaders))
        }
        Group {
            SectionLabel("Readers").padding(.top, Design.Space.xs)
            PropertyRow("Export data") {
                Picker("Export data", selection: bind(\.allowExportData)) {
                    Text("Not allowed").tag("none")
                    Text("Summarised data").tag("summarized")
                    Text("Summarised and underlying").tag("underlying")
                }
                .labelsHidden()
            }
            Toggle("Readers can personalise visuals", isOn: bind(\.allowPersonalizeVisuals))
            Toggle("Hide visual headers when reading", isOn: bind(\.hideVisualHeaders))
        }
        Group {
            SectionLabel("Document").padding(.top, Design.Space.xs)
            PropertyRow("Language") {
                Picker("Language", selection: bind(\.language)) {
                    ForEach(languages(including: s.language), id: \.self) { id in
                        Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                    }
                }
                .labelsHidden()
            }
            PropertyRow("Sensitivity") {
                CommitTextField("None", text: s.sensitivityLabel) { label in
                    store.mutate("Change Sensitivity Label", invalidates: .layout) { $0.report.settings.sensitivityLabel = label }
                }
            }
        }
        .controlSize(.small)
    }

    private func languages(including current: String) -> [String] {
        Self.languages.contains(current) ? Self.languages : [current] + Self.languages
    }

    private func bind<T: Equatable>(_ keyPath: WritableKeyPath<ReportSettings, T>, requery: Bool = false) -> Binding<T> {
        Binding(get: { store.report.settings[keyPath: keyPath] }, set: { value in
            guard store.report.settings[keyPath: keyPath] != value else { return }
            store.mutate("Change Report Settings", invalidates: requery ? .visuals(nil) : .layout) {
                $0.report.settings[keyPath: keyPath] = value
            }
        })
    }
}

/// A text field that writes to the document when editing ends, not on every keystroke.
