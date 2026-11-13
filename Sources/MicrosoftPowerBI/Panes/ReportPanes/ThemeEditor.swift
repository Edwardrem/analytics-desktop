import SwiftUI
import FacetCore
import FacetDesign

/// Inline editor for the report's current theme. Every change is one (coalesced) undo step.
struct ThemeEditor: View {
    @EnvironmentObject var store: DocumentStore
    @State private var dragging: String?

    private var theme: ThemeSpec { store.theme }
    private static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()
    private static let weights: [(id: String, title: String)] = [
        ("light", "Light"), ("regular", "Regular"), ("medium", "Medium"), ("semibold", "Semibold"), ("bold", "Bold"),
    ]

    var body: some View {
        Group {
            PropertyRow("Name") {
                CommitTextField("Theme name", text: theme.name) { name in
                    edit("name") { $0.name = name.isEmpty ? "Custom" : name }
                }
            }
            dataColours
            swatchRow("Sentiment", [("Good", \.good), ("Neutral", \.neutral), ("Bad", \.bad)])
            swatchRow("Divergent", [("Minimum", \.minimum), ("Center", \.center), ("Maximum", \.maximum)])
            swatchRow("Structural", [("Background", \.background), ("Card", \.cardBackground), ("Text", \.foreground)])
            swatchRow(nil, [("Secondary", \.secondaryForeground), ("Gridline", \.gridline), ("Accent", \.accent)])
        }
        Group {
            SectionLabel("Text").padding(.top, Design.Space.s)
            textStyle("Title", \.title)
            textStyle("Label", \.label)
            textStyle("Callout", \.callout)
            textStyle("Header", \.header)
        }
        Group {
            SectionLabel("Visual defaults").padding(.top, Design.Space.s)
            PropertyRow("Corner radius") { NumberField(label: "Corner radius", value: bind(\.cornerRadius, "radius"), range: 0...40, unit: "pt") }
            PropertyRow("Padding") { NumberField(label: "Padding", value: bind(\.visualPadding, "padding"), range: 0...48, unit: "pt") }
            Toggle("Shadow", isOn: visualDefault("shadow", fallback: false))
            Toggle("Border", isOn: visualDefault("border", fallback: false))
            Toggle("Title", isOn: visualDefault("title", fallback: true))
            Toggle("Subtitle", isOn: visualDefault("subtitle", fallback: false))
        }
        Group {
            SectionLabel("New pages").padding(.top, Design.Space.s)
            PageSizeControl(label: "Page size", size: theme.defaultPageSize ?? .widescreen) { size in
                edit("pageSize") { $0.defaultPageSize = size }
            }
            SectionLabel("Appearance").padding(.top, Design.Space.s)
            Toggle("Dark theme", isOn: bind(\.isDark, "dark"))
            Toggle("High contrast", isOn: bind(\.isHighContrast, "contrast"))
        }
    }

    // MARK: Editing

    private func edit(_ key: String, _ body: (inout ThemeSpec) -> Void) {
        store.mutate("Edit Theme", coalesce: "theme-\(key)", invalidates: .layout) { body(&$0.report.theme) }
    }
    private func bind<T: Equatable>(_ keyPath: WritableKeyPath<ThemeSpec, T>, _ key: String) -> Binding<T> {
        Binding(get: { store.theme[keyPath: keyPath] }, set: { value in
            guard store.theme[keyPath: keyPath] != value else { return }
            edit(key) { $0[keyPath: keyPath] = value }
        })
    }
    /// `visualDefaults["*"][card]["show"]`. A value equal to the renderer's own default is removed rather than stored.
    private func visualDefault(_ card: String, fallback: Bool) -> Binding<Bool> {
        Binding(get: { store.theme.visualDefaults["*"]?[card]?["show"]?.boolValue ?? fallback }, set: { value in
            edit("default-\(card)") { t in
                var all = t.visualDefaults["*"] ?? [:]
                var bag = all[card] ?? [:]
                bag["show"] = value == fallback ? nil : .bool(value)
                all[card] = bag.isEmpty ? nil : bag
                t.visualDefaults["*"] = all.isEmpty ? nil : all
            }
        })
    }

    // MARK: Data colours

    @ViewBuilder
    private var dataColours: some View {
        HStack {
            SectionLabel("Data colours")
            Button {
                edit("addColour") { t in t.dataColors.append(ThemeSpec.facet.dataColors[t.dataColors.count % ThemeSpec.facet.dataColors.count]) }
            } label: { Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 18).contentShape(Rectangle()) }
            .buttonStyle(.plain).help("Add a data colour").accessibilityLabel("Add a data colour")
        }
        .padding(.top, Design.Space.s)
        VStack(spacing: 1) {
            ForEach(Array(theme.dataColors.enumerated()), id: \.offset) { index, hex in
                HStack(spacing: Design.Space.s) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 14)
                        .help("Drag to reorder").accessibilityHidden(true)
                    HexColorWell(label: "Data colour \(index + 1)", hex: Binding(
                        get: { hex },
                        set: { new in edit("colour-\(index)") { if $0.dataColors.indices.contains(index) { $0.dataColors[index] = new } } }))
                    Text(hex.uppercased()).font(Design.Typeface.mono).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        edit("removeColour") { if $0.dataColors.indices.contains(index) { $0.dataColors.remove(at: index) } }
                    } label: { Image(systemName: "minus.circle").font(.system(size: 11)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(theme.dataColors.count <= 1)
                    .help("Remove this colour").accessibilityLabel("Remove data colour \(index + 1)")
                }
                .frame(height: 26)
                .contentShape(Rectangle())
                .reorderRow("c:\(index)", dragging: $dragging) { source in moveColour(source, to: index) }
            }
            Color.clear.frame(maxWidth: .infinity, minHeight: 10).contentShape(Rectangle())
                .reorderEnd("end", dragging: $dragging) { source in moveColour(source, to: theme.dataColors.count) }
        }
    }

    private func moveColour(_ source: String, to target: Int) {
        guard source.hasPrefix("c:"), let from = Int(source.dropFirst(2)), from != target else { return }
        edit("moveColour") { t in
            guard t.dataColors.indices.contains(from) else { return }
            let c = t.dataColors.remove(at: from)
            t.dataColors.insert(c, at: max(0, min(t.dataColors.count, from < target ? target - 1 : target)))
        }
    }

    // MARK: Swatches

    private func swatchRow(_ title: String?, _ items: [(String, WritableKeyPath<ThemeSpec, String>)]) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            if let title { SectionLabel(title).padding(.top, Design.Space.s) }
            HStack(alignment: .top, spacing: Design.Space.s) {
                ForEach(items, id: \.0) { label, keyPath in
                    VStack(alignment: .leading, spacing: Design.Space.xs) {
                        HexColorWell(label: label, hex: bind(keyPath, "swatch-\(label)"))
                        Text(label).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Text styles

    private func textStyle(_ label: String, _ keyPath: WritableKeyPath<ThemeSpec, TextStyle>) -> some View {
        let style = theme[keyPath: keyPath]
        return VStack(alignment: .leading, spacing: Design.Space.xs) {
            Text(label).font(Design.Typeface.caption).foregroundStyle(.secondary)
            HStack(spacing: Design.Space.s) {
                Picker("\(label) font", selection: bind(keyPath.appending(path: \.fontFamily), "\(label)-family")) {
                    Text("System").tag("")
                    Divider()
                    ForEach(fontChoices(including: style.fontFamily), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: .infinity)
                NumberField(label: "\(label) size", value: bind(keyPath.appending(path: \.size), "\(label)-size"), range: 6...96)
            }
            HStack(spacing: Design.Space.s) {
                Picker("\(label) weight", selection: bind(keyPath.appending(path: \.weight), "\(label)-weight")) {
                    ForEach(Self.weights, id: \.id) { Text($0.title).tag($0.id) }
                }
                .labelsHidden().frame(width: 104)
                OptionalHexColorWell(label: "\(label) colour", hex: bind(keyPath.appending(path: \.color), "\(label)-colour"),
                                     fallback: theme.foreground)
                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, Design.Space.xs)
    }

    private func fontChoices(including current: String) -> [String] {
        current.isEmpty || Self.fontFamilies.contains(current) ? Self.fontFamilies : [current] + Self.fontFamilies
    }
}

/// Page-size presets (16:9, 4:3, Letter, Tooltip) with custom width × height.
struct PageSizeControl: View {
    let label: String
    let size: PageSize
    let onChange: (PageSize) -> Void
    /// Stays on "Custom" while the typed size happens to equal a preset.
    @State private var forceCustom = false

    private var preset: PageSizePreset { forceCustom ? .custom : PageSizePreset.matching(size) }

    var body: some View {
        PropertyRow(label) {
            Picker(label, selection: Binding(get: { preset }, set: { choice in
                forceCustom = choice == .custom
                if let s = choice.size, s != size { onChange(s) }
            })) {
                ForEach(PageSizePreset.allCases) { p in
                    Text(p.size.map { "\(p.title) · \(Int($0.width)) × \(Int($0.height))" } ?? p.title).tag(p)
                }
            }
            .labelsHidden()
        }
        if preset == .custom {
            PropertyRow("Width") {
                NumberField(label: "Width", value: Binding(get: { size.width }, set: { onChange(PageSize(width: $0, height: size.height)) }),
                            range: 100...8000, step: 10, unit: "px")
            }
            PropertyRow("Height") {
                NumberField(label: "Height", value: Binding(get: { size.height }, set: { onChange(PageSize(width: size.width, height: $0)) }),
                            range: 100...8000, step: 10, unit: "px")
            }
        }
    }
}

// MARK: - Page settings

/// Settings for the current page: name, size, canvas background, wallpaper, visibility and tooltip use.
struct PageSettingsView: View {
    @EnvironmentObject var store: DocumentStore
    private var page: Page { store.currentPage }

    var body: some View {
        Group {
            PropertyRow("Name") {
                CommitTextField("Page name", text: page.name) { name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { store.updatePage(name: "Rename Page") { $0.name = trimmed } }
                }
            }
            PageSizeControl(label: "Size", size: page.size) { size in
                store.updatePage(name: "Change Page Size") { $0.size = size }
            }
        }
        Group {
            SectionLabel("Canvas background").padding(.top, Design.Space.s)
            background(\.background, fallback: store.theme.background, name: "Canvas Background")
            SectionLabel("Wallpaper").padding(.top, Design.Space.s)
            background(\.wallpaper, fallback: store.theme.background, name: "Wallpaper")
            PaneNote("The wallpaper fills the area around the page.")
        }
        Group {
            SectionLabel("Behaviour").padding(.top, Design.Space.s)
            Toggle("Hide this page from readers", isOn: Binding(
                get: { page.isHidden }, set: { on in store.updatePage(name: on ? "Hide Page" : "Show Page") { $0.isHidden = on } }))
            Toggle("Allow use as tooltip", isOn: Binding(
                get: { page.isTooltipPage },
                set: { on in store.updatePage(name: on ? "Use Page as Tooltip" : "Stop Using Page as Tooltip") { $0.isTooltipPage = on } }))
            PaneNote(page.isTooltipPage
                     ? "Visuals can show this page when you hover a data point. Tooltip pages work best at the Tooltip size and are usually hidden."
                     : "Turn this on to show the page as a rich tooltip when hovering data points in other visuals.")
            if page.isTooltipPage, page.size != .tooltip || !page.isHidden {
                Button("Use tooltip size and hide page") {
                    store.updatePage(name: "Set Up Tooltip Page") { $0.size = .tooltip; $0.isHidden = true }
                }
                .buttonStyle(.link).font(Design.Typeface.caption)
            }
        }
    }

    @ViewBuilder
    private func background(_ keyPath: WritableKeyPath<Page, BackgroundSpec>, fallback: String, name: String) -> some View {
        let spec = page[keyPath: keyPath]
        PropertyRow("Colour") {
            OptionalHexColorWell(label: "\(name) colour", hex: Binding(
                get: { spec.color },
                set: { hex in update(keyPath, name) { $0.color = hex } }), fallback: fallback)
        }
        PropertyRow("Transparency") {
            HStack(spacing: Design.Space.s) {
                Slider(value: Binding(get: { spec.transparency }, set: { v in update(keyPath, name) { $0.transparency = v.rounded() } }),
                       in: 0...100)
                    .accessibilityLabel("\(name) transparency")
                Text("\(Int(spec.transparency))%").font(Design.Typeface.caption).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
        }
        PropertyRow("Image") {
            HStack(spacing: Design.Space.s) {
                Button(spec.imageData == nil ? "Choose…" : "Replace…") {
                    if let data = ImagePicker.choose() { update(keyPath, name, coalesce: false) { $0.imageData = data } }
                }
                if spec.imageData != nil {
                    Button("Remove") { update(keyPath, name, coalesce: false) { $0.imageData = nil } }
                        .buttonStyle(.link).font(Design.Typeface.caption)
                }
            }
        }
        if spec.imageData != nil {
            PropertyRow("Image fit") {
                Picker("\(name) image fit", selection: Binding(get: { spec.imageFit }, set: { fit in update(keyPath, name, coalesce: false) { $0.imageFit = fit } })) {
                    Text("Normal").tag("normal")
                    Text("Fit").tag("fit")
                    Text("Fill").tag("fill")
                    Text("Tile").tag("tile")
                }
                .labelsHidden()
            }
        }
    }

    private func update(_ keyPath: WritableKeyPath<Page, BackgroundSpec>, _ name: String, coalesce: Bool = true,
                        _ body: (inout BackgroundSpec) -> Void) {
        let i = store.pageIndex
        store.mutate("Change \(name)", coalesce: coalesce ? "page-bg-\(name)" : nil, invalidates: .layout) { d in
            guard d.report.pages.indices.contains(i) else { return }
            body(&d.report.pages[i][keyPath: keyPath])
        }
    }
}
