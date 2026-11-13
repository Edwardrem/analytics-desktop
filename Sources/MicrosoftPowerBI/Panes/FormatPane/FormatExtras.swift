import SwiftUI
import FacetCore
import FacetDesign
import FacetVisuals

/// The Style presets card: applies one of the visual type's named styles to the selection.
struct FormatPresetRows: View {
    let specs: [VisualSpec]
    let theme: ThemeSpec
    /// Applies the named preset to every target visual.
    let apply: (String) -> Void

    private static let none = "", mixed = "\u{1F}mixed"

    var body: some View {
        let names = (specs.first.map { FormatPresets.presets(for: $0.type, theme: theme) } ?? []).map(\.name)
        let active = FormatValue(specs.map { FormatPresets.active(in: $0, theme: theme) })
        PropertyRow("Style preset") {
            Picker("Style preset", selection: Binding(
                get: { active?.isMixed ?? false ? Self.mixed : ((active?.value ?? nil) ?? Self.none) },
                set: { if $0 != Self.none, $0 != Self.mixed { apply($0) } })) {
                if active?.isMixed ?? false { Text("Mixed").tag(Self.mixed) }
                Text("Custom").tag(Self.none)
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .help("Apply a ready-made style. Settings the style does not cover are kept.")
        }
        .controlSize(.small)
    }
}

/// The Conditional formatting card: each target the visual supports, its state and an fx button.
struct FormatConditionalRows: View {
    let properties: [FormatProperty]
    let spec: VisualSpec

    var body: some View {
        ForEach(properties) { p in
            if let target = ConditionalFormat.Target(rawValue: p.key) {
                PropertyRow(p.label) {
                    HStack(spacing: Design.Space.s) {
                        Text(state(target)).font(Design.Typeface.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        FormatFxButton(visualID: spec.id, target: target)
                    }
                }
            }
        }
    }

    private func state(_ target: ConditionalFormat.Target) -> String {
        spec.conditionalFormats.first { $0.target == target }.map { BuildLogic.title($0.mode) } ?? "Off"
    }
}

/// The fx button: opens the conditional-formatting editor for one target of one visual.
struct FormatFxButton: View {
    @EnvironmentObject var store: DocumentStore
    let visualID: UUID
    let target: ConditionalFormat.Target
    @State private var open = false

    var body: some View {
        let active = store.visual(visualID)?.conditionalFormats.contains { $0.target == target } ?? false
        let name = BuildLogic.title(target).lowercased()
        IconButton("function", help: active ? "Edit conditional formatting for the \(name)" : "Conditional formatting for the \(name)",
                   isOn: active) { open = true }
            .popover(isPresented: $open, arrowEdge: .leading) {
                FormatFxEditor(visualID: visualID, target: target).environmentObject(store)
            }
    }
}

/// The fx popover: the Build pane's rule editor for one target, or the way to add the rule.
struct FormatFxEditor: View {
    @EnvironmentObject var store: DocumentStore
    let visualID: UUID
    let target: ConditionalFormat.Target

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("Conditional formatting").font(Design.Typeface.bodyStrong)
            if let spec = store.visual(visualID) {
                if let rule = spec.conditionalFormats.first(where: { $0.target == target }) {
                    ConditionalFormatsSection.RuleRow(spec: spec, rule: rule, expanded: true).id(rule.id)
                } else if spec.allFields.isEmpty {
                    PaneNote("Add a field to this visual first: a rule formats by a field's values.")
                } else {
                    PaneNote("Set the \(BuildLogic.title(target).lowercased()) from the data: by a colour scale, by rules, or from a field's value.")
                    Button("Add a rule") {
                        store.updateVisual(visualID, name: "Add Conditional Format") { v in
                            guard !v.conditionalFormats.contains(where: { $0.target == target }) else { return }
                            v.conditionalFormats.append(ConditionalFormatsSection.newRule(target, for: v))
                        }
                    }
                    .controlSize(.small)
                }
            } else {
                PaneNote("This visual is no longer on the page.")
            }
        }
        .padding(Design.Space.m)
        .frame(width: 280, alignment: .leading)
    }
}

/// On-object formatting: a button in the visual's header that lists the visual's elements, with
/// a switch for those that can be hidden and a way into the Format pane at that element's card.
struct FormatOnObjectButton: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    @State private var open = false

    var body: some View {
        IconButton("paintbrush", help: "Format this visual", isOn: open) {
            if !store.selection.contains(spec.id) { store.selection = store.withGroupMembers([spec.id]) }
            open = true
        }
        .popover(isPresented: $open, arrowEdge: .top) {
            FormatOnObjectList(visualID: spec.id) { open = false }.environmentObject(store)
        }
    }
}

struct FormatOnObjectList: View {
    @EnvironmentObject var store: DocumentStore
    let visualID: UUID
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let spec = store.visual(visualID) {
                Text(spec.name).font(Design.Typeface.bodyStrong).lineLimit(1)
                    .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(FormatCatalog.elements(for: spec.type)) { element in
                            row(element, spec)
                        }
                    }
                    .padding(.vertical, Design.Space.xs)
                }
                .frame(maxHeight: 320)
                Hairline()
                Button("Open the Format pane") { ShellState.of(store).show(.format); dismiss() }
                    .buttonStyle(.link).font(Design.Typeface.caption)
                    .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
            } else {
                PaneNote("This visual is no longer on the page.").padding(Design.Space.m)
            }
        }
        .frame(width: 240)
    }

    private func row(_ element: FormatCatalog.Element, _ spec: VisualSpec) -> some View {
        HStack(spacing: Design.Space.s) {
            Text(element.card.label).font(Design.Typeface.body).lineLimit(1)
            Spacer(minLength: Design.Space.s)
            if let toggle = element.toggle {
                Toggle(toggle.label, isOn: Binding(
                    get: { toggle.isOn(in: ResolvedFormat(spec: spec, theme: store.theme)) },
                    set: { on in
                        store.updateVisuals([visualID], name: "Format \(toggle.cardLabel)") {
                            $0.setFmt(toggle.card, toggle.key, FormatCatalog.stored(.bool(on), for: toggle))
                        }
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .help(toggle.label)
            }
            IconButton("chevron.right", help: "More \(element.card.label) options in the Format pane") {
                FormatFocus.shared.open(element.card.id, tab: element.tab, in: store)
                dismiss()
            }
        }
        .padding(.leading, Design.Space.m).padding(.trailing, Design.Space.xs)
    }
}
