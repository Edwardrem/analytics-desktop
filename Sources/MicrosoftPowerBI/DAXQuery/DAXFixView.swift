import SwiftUI
import FacetCore
import FacetCloud
import FacetDesign

/// One line of a line-by-line comparison of a failing query with its proposed fix.
struct DAXDiffLine: Equatable {
    enum Kind: Equatable { case same, removed, added }
    var kind: Kind
    var text: String
}

enum DAXDiff {
    /// Comparisons bigger than this many line pairs show as a full replacement; queries are far smaller.
    static let pairLimit = 250_000

    /// The lines of `old` and `new` aligned on their longest common subsequence: kept lines once, then the
    /// removed lines before the added ones at each change.
    static func lines(from old: String, to new: String) -> [DAXDiffLine] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        guard a.count * b.count <= pairLimit else {
            return a.map { DAXDiffLine(kind: .removed, text: $0) } + b.map { DAXDiffLine(kind: .added, text: $0) }
        }
        // common[i][j]: length of the longest common subsequence of a[i...] and b[j...].
        var common = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                common[i][j] = a[i] == b[j] ? common[i + 1][j + 1] + 1 : max(common[i + 1][j], common[i][j + 1])
            }
        }
        var out: [DAXDiffLine] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                out.append(DAXDiffLine(kind: .same, text: a[i])); i += 1; j += 1
            } else if common[i + 1][j] >= common[i][j + 1] {
                out.append(DAXDiffLine(kind: .removed, text: a[i])); i += 1
            } else {
                out.append(DAXDiffLine(kind: .added, text: b[j])); j += 1
            }
        }
        out += a[i...].map { DAXDiffLine(kind: .removed, text: $0) }
        out += b[j...].map { DAXDiffLine(kind: .added, text: $0) }
        return out
    }
}

/// What a fix is for: the text that failed in one tab, where it starts, and the error it raised.
struct DAXFixRequest: Equatable {
    var tab: UUID
    var original: String
    var offset: Int
    var error: String
}

/// "Fix with assistant" in the error banner of a failed run. It only shows when the assistant hook is set.
struct DAXFixButton: View {
    @ObservedObject var session: DAXQuerySession
    let run: DAXRunState
    @State private var fixing = false

    var body: some View {
        if DAXAssistantHook.fix != nil, let original = run.failedText, let error = run.error, let tab = session.activeTab {
            Button { fixing = true } label: { Label("Fix with assistant", systemImage: "wand.and.stars") }
                .buttonStyle(.link)
                .font(Design.Typeface.caption)
                .help("Ask the assistant for a corrected query, then review the change before it is applied")
                .popover(isPresented: $fixing, arrowEdge: .bottom) {
                    DAXFixPopover(session: session, isPresented: $fixing,
                                  request: DAXFixRequest(tab: tab.id, original: original, offset: run.failedOffset, error: error))
                }
        }
    }
}

private struct DAXFixPopover: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var session: DAXQuerySession
    @Binding var isPresented: Bool
    let request: DAXFixRequest
    @State private var proposal: String?
    @State private var failure: Error?
    @State private var edited = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("Fix with assistant").font(Design.Typeface.bodyStrong)
            if let failure {
                AssistantNotice(error: failure)
            } else if let proposal {
                Text("Review the proposed change. Accept replaces the query that failed and runs it.")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
                DAXDiffList(lines: DAXDiff.lines(from: request.original, to: proposal))
                if edited {
                    Text("The query was edited after it ran. Run it again, then ask for a fix.")
                        .font(Design.Typeface.caption).foregroundStyle(Design.Palette.caution)
                }
            } else {
                HStack(spacing: Design.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Fixing the query…").font(Design.Typeface.body).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                if proposal != nil, failure == nil {
                    Button("Reject") { isPresented = false }.keyboardShortcut(.cancelAction)
                    Button("Accept", action: accept).keyboardShortcut(.defaultAction).disabled(edited)
                } else {
                    Button("Close") { isPresented = false }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(Design.Space.l)
        .frame(width: 460)
        .task { await propose() }
    }

    private func propose() async {
        guard let fix = DAXAssistantHook.fix else { return }
        guard AssistantTasks.isConfigured else { failure = AssistantError.notConfigured; return }
        do { proposal = try await fix(request.original, request.error, store) }
        catch { failure = error }
    }

    private func accept() {
        guard let proposal else { return }
        if session.applyFix(proposal, tab: request.tab, original: request.original, offset: request.offset) {
            isPresented = false
        } else {
            edited = true
        }
    }
}

/// The diff as monospaced lines: removed lines tinted red with "−", added lines tinted green with "+".
private struct DAXDiffList: View {
    let lines: [DAXDiffLine]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: Design.Space.s) {
                        Text(marker(line.kind)).foregroundStyle(.secondary).frame(width: 10, alignment: .center)
                        Text(line.text.isEmpty ? " " : line.text).fixedSize()
                    }
                    .font(Design.Typeface.mono)
                    .padding(.horizontal, Design.Space.s)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(tint(line.kind))
                }
            }
            .textSelection(.enabled)
        }
        .frame(minHeight: 80, maxHeight: 320)
        .background(Design.Palette.fill)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).strokeBorder(Design.Palette.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Proposed change")
    }

    private func marker(_ kind: DAXDiffLine.Kind) -> String {
        switch kind { case .same: return " "; case .removed: return "−"; case .added: return "+" }
    }

    private func tint(_ kind: DAXDiffLine.Kind) -> Color {
        switch kind {
        case .same: return .clear
        case .removed: return Design.Palette.negative.opacity(0.12)
        case .added: return Design.Palette.positive.opacity(0.12)
        }
    }
}
