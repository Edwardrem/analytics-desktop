import SwiftUI
import FacetCore
import FacetCloud
import FacetDesign

/// Home ▸ Sensitivity: the Microsoft Purview labels the signed-in account may apply, listed from Microsoft Graph.
///
/// The chosen label is stored on the document (report settings), shown in the title bar, and travels with what the
/// document is saved or exported as: `.facet` documents, `.pbit` templates (package metadata) and Power BI projects
/// (report annotations). Analytics Desktop does not encrypt files; protection that a label enforces is applied by
/// Microsoft 365 services, not here.
struct SensitivitySheet: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var runtime = MicrosoftRuntime.shared
    @State private var labels: [SensitivityLabel] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var selection: String?

    private var current: String { store.report.settings.sensitivityLabel }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("Sensitivity").font(Design.Typeface.headline)
            Text(current.isEmpty ? "This document has no sensitivity label." : "This document is labelled “\(current)”.")
                .font(Design.Typeface.body).foregroundStyle(.secondary)
            if !runtime.hasWorkAccount {
                Text("Sensitivity labels come from your organization's Microsoft Purview policy. Sign in with a work or school account to see the labels you can apply.")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else if let failure {
                Text(failure).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative).fixedSize(horizontal: false, vertical: true)
            } else if labels.isEmpty {
                Text("Your organization hasn't published any sensitivity labels to you.").font(Design.Typeface.caption).foregroundStyle(.secondary)
            } else {
                List(SensitivityLabels.applicable(labels), selection: $selection) { label in
                    HStack(spacing: Design.Space.s) {
                        Circle().fill(SensitivityLabels.color(label)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(label.name ?? label.id)
                            if let tip = label.tooltip ?? label.description, !tip.isEmpty {
                                Text(tip).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        if (label.name ?? "") == current { Image(systemName: "checkmark").foregroundStyle(Design.Palette.accent) }
                    }
                    .tag(label.id)
                }
                .listStyle(.inset)
                .frame(minHeight: 200)
            }
            Text("The label is saved with the document and carried into templates and Power BI projects made from it. \(AppIdentity.name) doesn't encrypt files.")
                .font(Design.Typeface.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Remove Label") { apply(nil) }.disabled(current.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply(labels.first { $0.id == selection }) }
                    .keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
        }
        .padding(Design.Space.xl)
        .frame(width: 480)
        .task { await load() }
    }

    private func load() async {
        guard runtime.hasWorkAccount else { return }
        loading = true
        do {
            labels = try await runtime.services.fabric.sensitivityLabels()
            selection = labels.first { ($0.name ?? "") == current }?.id
        } catch {
            failure = AccountMessages.describe(error)
        }
        loading = false
    }

    private func apply(_ label: SensitivityLabel?) {
        let name = label.flatMap { $0.name ?? $0.id } ?? ""
        store.mutate(name.isEmpty ? "Remove Sensitivity Label" : "Apply Sensitivity Label", invalidates: .layout) {
            $0.report.settings.sensitivityLabel = name
        }
        store.status = StatusMessage(kind: .success, text: name.isEmpty ? "Removed the sensitivity label." : "Labelled the document “\(name)”.")
        dismiss()
    }
}

enum SensitivityLabels {
    /// Active labels, least sensitive first (the order Purview publishes them in).
    static func applicable(_ labels: [SensitivityLabel]) -> [SensitivityLabel] {
        labels.filter { $0.isActive != false }.enumerated().sorted { a, b in
            (a.element.sensitivity ?? Int.max, a.offset) < (b.element.sensitivity ?? Int.max, b.offset)
        }.map(\.element)
    }

    static func color(_ label: SensitivityLabel) -> Color {
        guard let hex = label.color?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#"), hex.count == 7 else { return Design.Palette.tertiaryText }
        return Color(hex: hex)
    }
}
