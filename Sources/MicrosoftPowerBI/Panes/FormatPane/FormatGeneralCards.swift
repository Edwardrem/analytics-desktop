import SwiftUI
import FacetCore
import FacetDesign

/// The General tab's Properties card: position and size. These live on the visual's frame rather
/// than in the format bag, so they write through `store.setFrames` and have no catalog default.
struct FormatPositionCard: View {
    let frame: Frame
    /// Writes x / y / width / height (points).
    let move: (String, Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Properties").font(Design.Typeface.bodyStrong)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.Space.m)
                .padding(.vertical, Design.Space.s)
            VStack(alignment: .leading, spacing: Design.Space.s) {
                PropertyRow("X") { field("x", frame.x, 0...4_000) }
                PropertyRow("Y") { field("y", frame.y, 0...4_000) }
                PropertyRow("Width") { field("width", frame.width, 20...4_000) }
                PropertyRow("Height") { field("height", frame.height, 20...4_000) }
                PropertyRow("Rotation") {
                    OptionalNumberField(value: frame.rotation == 0 ? nil : frame.rotation, onCommit: {
                        if let v = $0 { move("rotation", v) }
                    })
                    .accessibilityLabel("Rotation")
                    .help("Rotation in degrees — leave empty for none")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, Design.Space.m)
            .padding(.bottom, Design.Space.m)
            Hairline()
        }
        .controlSize(.small)
    }

    private func field(_ key: String, _ value: Double, _ range: ClosedRange<Double>) -> some View {
        CommitNumberField(value: value, range: range) { move(key, $0) }
            .accessibilityLabel(key == "x" ? "X position" : key == "y" ? "Y position" : key)
            .help(key == "x" || key == "y" ? "Position in points" : "Size in points")
    }
}

/// The General tab's Alt text card: read by screen readers instead of the visual's name.
struct FormatAltTextCard: View {
    let altText: String
    let commit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Alt text").font(Design.Typeface.bodyStrong)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.Space.m)
                .padding(.vertical, Design.Space.s)
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                CommitTextField("Describe this visual", text: altText, onCommit: commit)
                PaneNote("Read by screen readers instead of the visual's name.")
            }
            .padding(.leading, 14)
            .padding(.trailing, Design.Space.m)
            .padding(.bottom, Design.Space.m)
            Hairline()
        }
        .controlSize(.small)
    }
}
