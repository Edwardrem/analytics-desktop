import SwiftUI
import FacetDesign

/// The view switcher down the left edge: Report, Table, Model, DAX query, TMDL.
/// Icons only, as on Windows; the name and shortcut are in each button's tooltip.
struct ViewRail: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        VStack(spacing: Design.Space.xs) {
            ForEach(WorkspaceView.allCases) { view in
                RailButton(view: view, selected: store.view == view) {
                    AppCommands.run("view.\(view.rawValue)", store)
                }
            }
            Spacer()
            if !store.modelErrors.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Design.Palette.caution)
                    .help(store.modelErrors.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
                    .accessibilityLabel("\(store.modelErrors.count) model errors")
                    .padding(.bottom, Design.Space.s)
            }
        }
        .padding(.vertical, Design.Space.s)
        .frame(width: ShellMetrics.railWidth)
        .background(Design.Palette.surface)
    }
}

private struct RailButton: View {
    let view: WorkspaceView
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var help: String {
        let name = "\(view.title) view"
        guard let shortcut = AppCommands.command("view.\(view.rawValue)")?.shortcut else { return name }
        return "\(name) (\(ShortcutText.describe(shortcut)))"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: view.symbol)
                .font(.system(size: 16, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: ShellMetrics.railWidth - Design.Space.m, height: Design.Space.xxl + Design.Space.xs)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : (hovering ? Design.Palette.fill : Color.clear)))
                .frame(width: ShellMetrics.railWidth)
                .overlay(alignment: .leading) {
                    if selected {
                        Capsule().fill(Color.accentColor).frame(width: 3, height: Design.Space.l)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel("\(view.title) view")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
