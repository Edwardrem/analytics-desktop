import SwiftUI
import FacetCore
import FacetDesign
import FacetVisuals

/// The rows of the General tab's Properties card: position, size and rotation. These live on the
/// visual's frame rather than in the format bag, so they have no catalog default to reset to.
struct FormatPositionRows: View {
    /// The rows to show (a search can narrow them).
    let properties: [FormatProperty]
    /// The frame in the layout being edited (desktop or phone).
    let frame: Frame
    /// Writes one of x / y / width / height / rotation (nil rotation = none).
    let move: (String, Double?) -> Void

    var body: some View {
        ForEach(properties) { p in
            PropertyRow(p.label) {
                FormatNumberField(label: Self.name(p.key), value: value(p.key),
                                  placeholder: p.key == "rotation" ? "None" : "",
                                  bounds: p.bounds, allowsEmpty: p.key == "rotation") {
                    move(p.key, $0)
                }
            }
        }
        .controlSize(.small)
    }

    private func value(_ key: String) -> Double? {
        switch key {
        case "x": return frame.x
        case "y": return frame.y
        case "width": return frame.width
        case "height": return frame.height
        case "rotation": return frame.rotation == 0 ? nil : frame.rotation
        default: return nil
        }
    }

    private static func name(_ key: String) -> String {
        switch key {
        case "x": return "X position in points"
        case "y": return "Y position in points"
        case "width": return "Width in points"
        case "height": return "Height in points"
        default: return "Rotation in degrees"
        }
    }
}

/// The rows of the General tab's Tooltip card: the report page shown when readers hover over the visual.
struct FormatTooltipRows: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    let choose: (UUID?) -> Void

    var body: some View {
        let pages = store.report.pages.filter(\.isTooltipPage)
        if pages.isEmpty {
            PaneNote("Design a small page to show when readers hover over this visual.")
            Button("New tooltip page") { AppCommands.run("insert.tooltipPage", store) }.controlSize(.small)
        } else {
            PropertyRow("Tooltip page") {
                Picker("Tooltip page", selection: Binding(get: { spec.tooltipPageID }, set: choose)) {
                    Text("Default tooltip").tag(UUID?.none)
                    ForEach(pages) { p in Text(p.name).tag(UUID?.some(p.id)) }
                }
                .labelsHidden()
                .help("The page shown as this visual's tooltip")
            }
            .controlSize(.small)
        }
    }
}

/// The rows of the General tab's Alt text card: read by screen readers instead of the visual's name.
struct FormatAltTextRows: View {
    let visualID: UUID
    let altText: String
    let commit: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
            CommitTextField("Describe this visual", text: altText, onCommit: commit)
                .accessibilityLabel("Alt text")
            FormatBindingButton(visualID: visualID, card: FormatBinding.altTextCard, key: "text", name: "alt text", kind: .text)
        }
        PaneNote("Read by screen readers instead of the visual's name.")
    }
}

/// The rows of the General tab's Action card: the text shown when readers hover over the visual.
struct FormatActionTooltipRows: View {
    let visualID: UUID
    let tooltip: String
    let commit: (String) -> Void

    var body: some View {
        PropertyRow("Tooltip") {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                CommitTextField("Shown on hover", text: tooltip, onCommit: commit)
                    .accessibilityLabel("Tooltip")
                FormatBindingButton(visualID: visualID, card: FormatBinding.actionCard, key: "tooltip",
                                    name: "action tooltip", kind: .text)
            }
        }
        .controlSize(.small)
        PaneNote("Shown when readers hover over this visual. Set what it does in the Build pane.")
    }
}
