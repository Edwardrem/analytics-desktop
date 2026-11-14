import SwiftUI
import FacetCore
import FacetDesign
import FacetVisuals

/// The fx button next to a Format pane property that can take its value from a field: opens the
/// editor for that property's `FormatBinding`, highlighted while one is set.
struct FormatBindingButton: View {
    @EnvironmentObject var store: DocumentStore
    let visualID: UUID
    let card: String
    let key: String
    /// The property in a sentence ("subtitle text", "width of Region").
    let name: String
    let kind: FormatBinding.Kind
    @State private var open = false

    var body: some View {
        let active = store.visual(visualID)?.formatBinding(card, key) != nil
        IconButton("function", help: active ? "Edit how a field sets the \(name)" : "Set the \(name) from a field",
                   isOn: active) { open = true }
            .popover(isPresented: $open, arrowEdge: .leading) {
                FormatBindingEditor(visualID: visualID, card: card, key: key, name: name, kind: kind)
                    .environmentObject(store)
            }
    }

    /// How a Format pane row reads in a sentence.
    static func name(of property: FormatProperty) -> String {
        if property.card == "columnWidths" { return "width of \(property.label)" }
        if property.card == FormatBinding.altTextCard { return "alt text" }
        if property.card == FormatBinding.actionCard { return "action tooltip" }
        let label = property.label.lowercased()
        let card = property.cardLabel.lowercased()
        return label.contains(card) ? label : "\(card) \(label)"
    }
}

/// The fx popover: format style, the field it is based on, and the style's settings.
struct FormatBindingEditor: View {
    @EnvironmentObject var store: DocumentStore
    let visualID: UUID
    let card: String
    let key: String
    let name: String
    let kind: FormatBinding.Kind

    private static let operators: [FilterOperator] = [.greaterOrEqual, .greaterThan, .lessThan, .lessOrEqual, .equals, .notEquals, .isBlank]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("Conditional formatting").font(Design.Typeface.bodyStrong)
            Text(name.prefix(1).uppercased() + name.dropFirst()).font(Design.Typeface.caption).foregroundStyle(.secondary)
            if let spec = store.visual(visualID) {
                if let binding = spec.formatBinding(card, key) {
                    editor(binding)
                } else {
                    PaneNote(intro)
                    Button("Set from a field") {
                        store.updateVisual(visualID, name: "Add Conditional Format") { v in
                            guard v.formatBinding(card, key) == nil else { return }
                            v.setFormatBinding(card, key, FormatBindings.newBinding(card: card, key: key, kind: kind, for: v))
                        }
                    }
                    .controlSize(.small)
                }
            } else {
                PaneNote("This visual is no longer on the page.")
            }
        }
        .padding(Design.Space.m)
        .frame(width: 300, alignment: .leading)
    }

    private var intro: String {
        switch kind {
        case .text: return "Show a field's value, under the visual's filters, as the \(name)."
        case .color: return "Set the \(name) from a field: by a colour scale, by rules, or from a field whose value is a colour."
        case .number: return "Set the \(name) from a field: by rules, or from a field whose value is the width in points."
        }
    }

    @ViewBuilder private func editor(_ b: FormatBinding) -> some View {
        let modes = FormatBindings.modes(for: kind)
        if modes.count > 1 {
            PropertyRow("Format style") {
                Picker("Format style", selection: Binding(get: { b.mode }, set: { mode in
                    update("Change Format Style") { x in
                        x.mode = mode
                        if mode == .rules, x.rules.isEmpty { x.rules = [FormatBindings.newRule(kind: kind)] }
                    }
                })) {
                    ForEach(modes, id: \.self) { Text(BuildLogic.title($0)).tag($0) }
                }
                .labelsHidden()
                .help("How the field's value sets the \(name)")
            }
        }
        PropertyRow("Based on field") {
            FieldPickerButton(selection: b.field, placeholder: "Choose a field", allowsClear: false) { f in
                update("Change Conditional Format Field") { $0.field = f }
            }
        }
        switch b.mode {
        case .fieldValue: PaneNote(fieldValueNote)
        case .gradient: gradientRows(b)
        case .rules: ruleRows(b)
        }
        currentValue
        Hairline()
        Button("Remove", role: .destructive) {
            store.updateVisual(visualID, name: "Remove Conditional Format") { $0.setFormatBinding(card, key, nil) }
        }
        .buttonStyle(.link).font(Design.Typeface.caption)
        .help("Go back to the static \(name)")
    }

    private var fieldValueNote: String {
        switch kind {
        case .text: return "The field's value, formatted, replaces the text. A blank value shows the static text."
        case .color: return "The field's value must be a colour: a hex code such as #0A84FF, or a name such as red."
        case .number: return "The field's value is the width in points, from 28 to 2,000."
        }
    }

    @ViewBuilder private func gradientRows(_ b: FormatBinding) -> some View {
        PropertyRow("Lowest value") {
            HStack(spacing: Design.Space.s) {
                CommitNumberField(value: b.minValue, width: 72) { v in update("Change Gradient") { $0.minValue = v } }
                    .accessibilityLabel("Lowest value")
                HexColorWell(label: "Colour at the lowest value", hex: Binding(get: { b.minColor }, set: { c in
                    update("Change Gradient", coalesce: "min") { $0.minColor = c }
                }))
            }
        }
        PropertyRow("Highest value") {
            HStack(spacing: Design.Space.s) {
                CommitNumberField(value: b.maxValue, width: 72) { v in update("Change Gradient") { $0.maxValue = v } }
                    .accessibilityLabel("Highest value")
                HexColorWell(label: "Colour at the highest value", hex: Binding(get: { b.maxColor }, set: { c in
                    update("Change Gradient", coalesce: "max") { $0.maxColor = c }
                }))
            }
        }
        if b.maxValue <= b.minValue {
            PaneNote("The highest value must be above the lowest: until then every value gets the highest colour.")
        }
    }

    @ViewBuilder private func ruleRows(_ b: FormatBinding) -> some View {
        ForEach(Array(b.rules.enumerated()), id: \.offset) { i, rule in
            HStack(spacing: Design.Space.xs) {
                Text(i == 0 ? "If value" : "Else if").font(Design.Typeface.caption).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Picker("Condition of rule \(i + 1)", selection: Binding(get: { rule.op }, set: { op in
                    updateRule(i) { $0.op = op }
                })) {
                    ForEach(Self.operators, id: \.self) { Text(Self.symbol($0)).tag($0) }
                }
                .labelsHidden().frame(width: 58)
                .help("Condition of rule \(i + 1)")
                if rule.op.needsValue {
                    CommitNumberField(value: rule.value, width: 52) { v in updateRule(i) { $0.value = v } }
                        .accessibilityLabel("Value of rule \(i + 1)")
                }
                Image(systemName: "arrow.right").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                if kind == .color {
                    HexColorWell(label: "Colour of rule \(i + 1)", hex: Binding(get: { rule.color }, set: { c in
                        updateRule(i, coalesce: "rule\(i)") { $0.color = c }
                    }))
                } else {
                    CommitNumberField(value: rule.number ?? 120, width: 52, range: 28...2_000) { v in updateRule(i) { $0.number = v } }
                        .accessibilityLabel("Width of rule \(i + 1)")
                }
                Spacer(minLength: 0)
                MiniIconButton("minus.circle", help: "Remove rule \(i + 1)") {
                    update("Remove Rule") { x in if x.rules.indices.contains(i) { x.rules.remove(at: i) } }
                }
            }
            .controlSize(.small)
        }
        Button("New rule") { update("Add Rule") { $0.rules.append(FormatBindings.newRule(kind: kind)) } }
            .controlSize(.small)
        PaneNote("The first rule the value meets applies. When none does, the static setting shows.")
    }

    /// What the binding gives right now, under the visual's filters.
    @ViewBuilder private var currentValue: some View {
        if let value = store.visualData[visualID]?.formatOverrides[card]?[key] {
            HStack(spacing: Design.Space.xs) {
                Text("Now").font(Design.Typeface.caption).foregroundStyle(.secondary)
                if kind == .color, let hex = value.stringValue {
                    Circle().fill(Color(hex: hex)).frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Design.Palette.hairlineStrong, lineWidth: 0.5))
                        .accessibilityHidden(true)
                }
                Text(Self.describe(value, kind: kind)).font(Design.Typeface.caption).lineLimit(2)
                    .textSelection(.enabled)
            }
        } else {
            PaneNote("Under the current filters the field gives no value for this, so the static setting shows.")
        }
    }

    static func describe(_ value: JSONValue, kind: FormatBinding.Kind) -> String {
        switch value {
        case .number(let d): return Value.double(d).asString + (kind == .number ? " pt" : "")
        case .string(let s): return s
        default: return ""
        }
    }

    static func symbol(_ op: FilterOperator) -> String {
        switch op {
        case .greaterOrEqual: return "≥"
        case .greaterThan: return ">"
        case .lessThan: return "<"
        case .lessOrEqual: return "≤"
        case .equals: return "="
        case .notEquals: return "≠"
        case .isBlank: return "is blank"
        default: return op.displayName
        }
    }

    // MARK: - Writes (each is one undo step; colour drags coalesce)

    private func update(_ name: String, coalesce: String? = nil, _ body: @escaping (inout FormatBinding) -> Void) {
        let card = card, key = key
        store.updateVisual(visualID, name: name, coalesce: coalesce.map { "fx-\(visualID.uuidString)-\(card).\(key)-\($0)" }) { v in
            guard var b = v.formatBinding(card, key) else { return }
            body(&b)
            v.setFormatBinding(card, key, b)
        }
    }

    private func updateRule(_ i: Int, coalesce: String? = nil, _ body: @escaping (inout ConditionalFormat.Rule) -> Void) {
        update("Change Rule", coalesce: coalesce) { b in
            guard b.rules.indices.contains(i) else { return }
            body(&b.rules[i])
        }
    }
}
