import SwiftUI
import FacetCore
import FacetDesign
import FacetVisuals

/// One row of the Format pane: the property label on the left, the catalog kind's control on the
/// right. The row shows the value in effect on `specs` (one visual, or several with "Mixed" where
/// they differ) and reports edits through `write`; it never touches the model itself.
struct FormatPropertyRow: View {
    let property: FormatProperty
    /// The visuals this row edits. Fixed for the row's lifetime, so a late commit can't land elsewhere.
    let specs: [VisualSpec]
    let theme: ThemeSpec
    /// Writes `value` (nil = back to the default) for the property.
    let write: (FormatProperty, JSONValue?) -> Void

    var body: some View {
        PropertyRow(property.label) { control }
            .controlSize(.small)
    }

    private var current: FormatValue<JSONValue?>? { FormatCatalog.value(of: property, in: specs, theme: theme) }
    private var isMixed: Bool { current?.isMixed ?? false }
    private var shared: JSONValue? { current?.value ?? nil }

    @ViewBuilder private var control: some View {
        switch property.kind {
        case .bool:
            let state = FormatCatalog.isOn(property, in: specs, theme: theme)
            HStack(spacing: Design.Space.s) {
                Toggle(property.label, isOn: Binding(
                    get: { state?.value ?? false },
                    set: { write(property, .bool($0)) }))
                    .labelsHidden()
                if state?.isMixed ?? false { mixedTag }
            }
        case .number:
            FormatNumberField(label: property.label, value: shared?.doubleValue,
                              placeholder: isMixed ? "Mixed" : "Auto", bounds: property.bounds) {
                write(property, $0.map(JSONValue.number))
            }
        case .string:
            CommitTextField(isMixed ? "Mixed" : stringPlaceholder, text: shared?.stringValue ?? "") {
                write(property, .string($0))
            }
            .accessibilityLabel(property.label)
            .help("\(property.label). Leave empty for the default.")
        case .color:
            HStack(spacing: Design.Space.s) {
                OptionalHexColorWell(label: property.label, hex: Binding(
                    get: { isMixed ? nil : specs.first?.fmt(property.card, property.key)?.stringValue },
                    set: { write(property, $0.map(JSONValue.string)) }),
                    fallback: shared?.stringValue ?? FormatCatalog.defaultColor(of: property, theme: theme))
                if isMixed { mixedTag }
            }
        case .field:
            let captions = FormatCatalog.fieldCaptions(in: specs)
            let chosen = shared?.stringValue ?? ""
            Picker(property.label, selection: Binding(
                get: { isMixed ? Self.mixedOption : chosen },
                set: { choice in
                    guard choice != Self.mixedOption else { return }
                    write(property, choice.isEmpty ? nil : .string(choice))
                })) {
                if isMixed { Text("Mixed").tag(Self.mixedOption) }
                Text("None").tag("")
                // A field that has since left the visual stays visible so it can be cleared.
                if !chosen.isEmpty, !captions.contains(chosen) { Text("\(chosen) (not in this visual)").tag(chosen) }
                ForEach(captions, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .help(property.label)
        case .options(let options):
            // An option list with no fixed default lets the renderer decide: "Automatic" removes the override.
            let automatic = property.defaultValue == .null
            Picker(property.label, selection: Binding(
                get: { isMixed ? Self.mixedOption : (shared?.stringValue ?? "") },
                set: { choice in
                    guard choice != Self.mixedOption else { return }
                    write(property, choice.isEmpty ? nil : .string(choice))
                })) {
                if isMixed { Text("Mixed").tag(Self.mixedOption) }
                if automatic { Text("Automatic").tag("") }
                ForEach(options, id: \.self) { Text(Self.optionName($0)).tag($0) }
            }
            .labelsHidden()
            .help(property.label)
        }
    }

    private var mixedTag: some View {
        Text("Mixed").font(Design.Typeface.caption).foregroundStyle(.tertiary)
            .help("The selected visuals have different values")
    }

    /// The automatic title is shown as the placeholder of an unset title.
    private var stringPlaceholder: String {
        if property.card == "title", property.key == "text", specs.count == 1, let spec = specs.first {
            let auto = VisualTitles.automatic(for: spec)
            if !auto.isEmpty { return auto }
        }
        return "Auto"
    }

    private static let mixedOption = "\u{1F}mixed"

    /// Wording for option values shown in menus ("insideEnd" → "Inside end").
    static func optionName(_ value: String) -> String {
        switch value {
        case "auto": return "Automatic"
        case "insideCenter", "center": return "Centre"
        case "categoryPercent": return "Category and percent"
        case "categoryValue": return "Category and value"
        case "linear": return "Straight"
        case "first": return "First stage"
        case "previous": return "Previous stage"
        default: return FormatCatalog.sentenceCase(value)
        }
    }
}

/// Number field for the Format pane: commits on Return or when focus leaves, clamps to the
/// property's bounds, and says so in place when the text is not a number instead of dropping it.
struct FormatNumberField: View {
    let label: String
    /// nil = no override (automatic) or mixed.
    let value: Double?
    var placeholder = "Auto"
    let bounds: ClosedRange<Double>
    /// False for values that have no automatic state (position, size).
    var allowsEmpty = true
    let onCommit: (Double?) -> Void

    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
                .onAppear { draft = text(value) }
                .onChange(of: value) { _, v in if !focused { draft = text(v); error = nil } }
                .accessibilityLabel(label)
                .help(allowsEmpty ? "\(label). Leave empty for the default." : label)
            if let error {
                Text(error).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(label): \(error)")
            }
        }
    }

    private func text(_ v: Double?) -> String { v.map { Value.double($0).asString } ?? "" }

    private func commit() {
        switch FormatCatalog.numberInput(draft, bounds: bounds, allowsEmpty: allowsEmpty) {
        case .clear:
            error = nil
            if value != nil { onCommit(nil) }
        case .value(let v):
            error = nil
            draft = text(v)
            if v != value { onCommit(v) }
        case .invalid(let message):
            error = message
        }
    }
}
