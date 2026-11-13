import SwiftUI
import FacetCore
import FacetDesign

/// One row of the Format pane: the property label on the left, the catalog kind's control on the
/// right. All writes go through the pane's `write` closure (never directly into the model).
struct FormatPropertyRow: View {
    let property: FormatPropertyModel
    let spec: VisualSpec
    let theme: ThemeSpec
    /// Writes `value` (nil = reset to the renderer default) for the property.
    let write: (FormatPropertyModel, JSONValue?) -> Void

    var body: some View {
        PropertyRow(property.label) { control }
            .controlSize(.small)
    }

    /// The value currently stored, or nil when the key is absent (follows the default).
    private var current: JSONValue? { spec.fmt(property.card, property.key) }

    @ViewBuilder private var control: some View {
        switch property.kind {
        case .bool:
            Toggle(property.label, isOn: Binding(
                get: { current?.boolValue ?? property.defaultValue?.boolValue ?? false },
                set: { write(property, .bool($0)) }))
                .labelsHidden()
        case .number:
            OptionalNumberField(value: current?.doubleValue, onCommit: {
                write(property, $0.map(JSONValue.number))
            })
            .accessibilityLabel(property.label)
            .help("\(property.label) — leave empty for the default")
        case .string:
            CommitTextField(property.label,
                            text: current?.stringValue ?? property.defaultValue?.stringValue ?? "") {
                write(property, .string($0))
            }
        case .color:
            OptionalHexColorWell(label: property.label, hex: Binding(
                get: { current?.stringValue },
                set: { write(property, $0.map(JSONValue.string)) }),
                fallback: Self.colorFallback(card: property.card, key: property.key, theme: theme))
        case .enumeration(let options):
            Picker(property.label, selection: Binding(
                get: { current?.stringValue ?? property.defaultValue?.stringValue ?? options.first ?? "" },
                set: { write(property, .string($0)) })) {
                ForEach(options, id: \.self) { Text(Self.optionName($0)).tag($0) }
            }
            .labelsHidden()
            .help(property.label)
        }
    }

    /// The colour the well previews while the key is unset — the renderer's fallback for that card.
    private static func colorFallback(card: String, key: String, theme: ThemeSpec) -> String {
        switch (card, key) {
        case ("subtitle", "color"): return theme.secondaryForeground
        case ("divider", "color"), ("grid", "color"), ("border", "color"): return theme.gridline
        case ("background", "color"): return theme.cardBackground
        case ("columnHeaders", "color"), ("total", "color"): return theme.foreground
        case ("gauge", "fillColor"), ("path", "color"): return theme.dataColors.first ?? theme.accent
        default: break
        }
        switch key {
        case "selectedColor": return theme.accent
        case "goodColor", "increaseColor", "upColor": return theme.good
        case "badColor", "decreaseColor", "downColor": return theme.bad
        case "neutralColor": return theme.neutral
        case "background", "alternateBackground": return theme.cardBackground
        default: return theme.foreground
        }
    }

    /// "displayUnits" → "Display units" style wording for option values shown in menus.
    static func optionName(_ value: String) -> String {
        switch value {
        case "auto": return "Automatic"
        case "none": return "None"
        case "thousands": return "Thousands"
        case "millions": return "Millions"
        case "billions": return "Billions"
        case "trillions": return "Trillions"
        case "outsideEnd": return "Outside end"
        case "insideEnd": return "Inside end"
        case "insideCenter": return "Centre"
        case "insideBase": return "Inside base"
        case "left": return "Left"
        case "center": return "Centre"
        case "right": return "Right"
        case "categoryPercent": return "Category and percent"
        case "category": return "Category"
        case "percent": return "Percent"
        case "value": return "Value"
        case "smooth": return "Smooth"
        case "linear": return "Straight"
        case "step": return "Step"
        case "solid": return "Solid"
        case "dashed": return "Dashed"
        case "dotted": return "Dotted"
        case "first": return "First stage"
        case "previous": return "Previous stage"
        case "count": return "Count"
        case "top": return "Top"
        case "bottom": return "Bottom"
        default: return value
        }
    }
}

/// One collapsible card of the Format pane: a quiet header with the card name and a reset button,
/// then the property rows. The pane owns the expansion state so Expand/Collapse all works.
struct FormatCardView: View {
    let card: FormatCardModel
    let spec: VisualSpec
    let theme: ThemeSpec
    @Binding var expanded: Bool
    /// Writes one property (nil = reset).
    let write: (FormatPropertyModel, JSONValue?) -> Void
    /// Resets every key of the card to its renderer default.
    let reset: () -> Void

    private var isOverridden: Bool { FormatCatalog.isOverridden(card, in: spec) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.Space.xs) {
                Button { withAnimation(Design.Motion.quick) { expanded.toggle() } } label: {
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                            .frame(width: 10)
                        Text(card.label).font(Design.Typeface.bodyStrong)
                        Spacer(minLength: Design.Space.s)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, Design.Space.s)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(card.label)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                IconButton("arrow.counterclockwise", help: "Reset \(card.label) to default", isOn: isOverridden) {
                    reset()
                }
                .disabled(!isOverridden)
            }
            .padding(.horizontal, Design.Space.m)
            if expanded {
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    ForEach(card.properties) { property in
                        FormatPropertyRow(property: property, spec: spec, theme: theme, write: write)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, Design.Space.m)
                .padding(.bottom, Design.Space.m)
            }
            Hairline()
        }
    }
}
