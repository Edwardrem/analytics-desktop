import SwiftUI
import FacetCore
import FacetDesign
import FacetInterop

/// Confirmation for applying the active TMDL script: what it would add, change and remove, the
/// per-file line diffs, and any warnings. Nothing is written until "Apply" runs, which is one
/// undoable edit through `DocumentStore.mutate`.
struct TMDLApplySheet: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: TMDLViewSession
    @Binding var isPresented: Bool
    @State private var result: TMDLApplyResult?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text("Apply the script to the model?").font(Design.Typeface.headline)
                Text("The objects in this script are created or replaced. Applying is one undoable change.")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
            .padding(Design.Space.l)
            Hairline()
            if let failure {
                EmptyState(systemImage: "exclamationmark.triangle", title: "This script can't be applied", message: failure)
                footer
            } else if let result {
                summary(result)
                footer
            } else {
                HStack(spacing: Design.Space.s) { ProgressView().controlSize(.small); Text("Comparing with the model…").foregroundStyle(.secondary) }
                    .font(Design.Typeface.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                footer
            }
        }
        .frame(width: 620)
        .frame(minHeight: 300, maxHeight: 620)
        .task { compute() }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
            if let result {
                Button("Apply") {
                    session.apply(result)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(result.summary.isEmpty || result.warnings.contains { $0.severity == .error })
            }
        }
        .padding(Design.Space.l)
    }

    private func compute() {
        do {
            result = try session.previewApply()
            failure = nil
        } catch let e as TMDLError {
            result = nil
            failure = e.errorDescription ?? e.message
        } catch {
            result = nil
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Content

    private func summary(_ result: TMDLApplyResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.l) {
                let s = result.summary
                if s.isEmpty && result.warnings.isEmpty {
                    Text("This script matches the model; nothing would change.")
                        .font(Design.Typeface.body).foregroundStyle(.secondary)
                } else {
                    if !s.isEmpty { changeList(s) }
                    if !result.warnings.isEmpty { warningList(result.warnings) }
                    if !result.fileDiffs.isEmpty { fileDiffs(result.fileDiffs) }
                }
            }
            .padding(Design.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func changeList(_ s: TMDLChangeSummary) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(spacing: Design.Space.xs) {
                Chip("\(s.added.count) added", tint: Design.Palette.positive)
                Chip("\(s.changed.count) changed", tint: Design.Palette.caution)
                Chip("\(s.removed.count) removed", tint: Design.Palette.negative)
            }
            ForEach(s.changes, id: \.self) { change in
                HStack(spacing: Design.Space.s) {
                    Text(change.kind.rawValue.capitalized).font(Design.Typeface.caption)
                        .foregroundStyle(tint(for: change.kind)).frame(width: 56, alignment: .leading)
                    Text(change.objectType).font(Design.Typeface.caption).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                    Text(change.name).font(Design.Typeface.body).lineLimit(1).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func warningList(_ warnings: [ImportWarning]) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            ForEach(warnings.indices, id: \.self) { i in
                let warning = warnings[i]
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                    Image(systemName: warning.severity == .error ? "exclamationmark.octagon" : "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundStyle(warning.severity == .error ? Design.Palette.negative : Design.Palette.caution)
                    Text(warning.description).font(Design.Typeface.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func fileDiffs(_ diffs: [TMDLFileDiff]) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            ForEach(diffs, id: \.path) { diff in
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text("definition/\(diff.path)").font(Design.Typeface.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Chip(diff.status.rawValue, tint: diff.status == .added ? Design.Palette.positive : diff.status == .removed ? Design.Palette.negative : .primary)
                        Spacer(minLength: 0)
                    }
                    TMDLFileDiffView(hunks: diff.hunks)
                }
            }
        }
    }

    private func tint(for kind: TMDLChange.Kind) -> Color {
        switch kind {
        case .added: return Design.Palette.positive
        case .changed: return Design.Palette.caution
        case .removed: return Design.Palette.negative
        }
    }
}

/// Line diff of one TMDL file: removed lines above added ones, each marked in the margin and numbered.
struct TMDLFileDiffView: View {
    let hunks: [TextDiff.Hunk]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hunks.indices, id: \.self) { index in
                let hunk = hunks[index]
                if index > 0 {
                    HStack(spacing: Design.Space.s) {
                        Text("⋯").font(Design.Typeface.mono).foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                }
                ForEach(hunk.lines.indices, id: \.self) { lineIndex in
                    let line = hunk.lines[lineIndex]
                    HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                        Text(margin(for: line)).font(Design.Typeface.mono).foregroundStyle(.secondary).frame(width: 10)
                        Text(number(for: line)).font(Design.Typeface.mono).foregroundStyle(.tertiary)
                            .frame(width: 34, alignment: .trailing).monospacedDigit()
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(line.kind == .context ? .secondary : .primary)
                            .strikethrough(line.kind == .removed, color: .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(Design.Typeface.mono)
                    .padding(.horizontal, Design.Space.s)
                    .padding(.vertical, 1)
                    .background(line.kind == .added ? Design.Palette.positive.opacity(0.12)
                                : (line.kind == .removed ? Design.Palette.negative.opacity(0.1) : Color.clear))
                    .accessibilityLabel("\(line.kind == .added ? "Added" : (line.kind == .removed ? "Removed" : "Unchanged")) line \(number(for: line)): \(line.text)")
                }
            }
        }
        .padding(.vertical, Design.Space.xs)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(Design.Palette.fill))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
    }

    private func margin(for line: TextDiff.Line) -> String {
        line.kind == .added ? "+" : (line.kind == .removed ? "−" : " ")
    }

    private func number(for line: TextDiff.Line) -> String {
        switch line.kind {
        case .added: return line.newNumber.map { "\($0)" } ?? ""
        case .removed: return line.oldNumber.map { "\($0)" } ?? ""
        case .context: return line.newNumber.map { "\($0)" } ?? ""
        }
    }
}
