import SwiftUI
import AppKit
import FacetCore
import FacetDesign
import FacetVisuals

extension ScriptVisuals {
    /// The renderer of a Python or R visual on the canvas (nil for any other visual).
    @MainActor static func view(_ spec: VisualSpec, _ data: VisualData, _ context: VisualContext, _ store: DocumentStore) -> AnyView? {
        guard let language = ScriptLanguage(spec.type) else { return nil }
        return AnyView(ScriptVisualView(runtime: .of(store), spec: spec, data: data, language: language,
                                        interactive: context.isInteractive))
    }

    /// R in the script editor: keywords and # comments.
    @MainActor static let rLanguage = LanguageSupport.lexical(
        name: "R", keywords: ["function", "if", "else", "for", "while", "repeat", "in", "next", "break", "return",
                              "TRUE", "FALSE", "NULL", "NA", "Inf", "NaN", "library", "require"],
        lineComments: ["#"], fieldsInBrackets: false, caseInsensitive: false)
}

/// A script visual: the plot its script drew at the visual's size, or what it needs first.
struct ScriptVisualView: View {
    @ObservedObject var runtime: ScriptVisualRuntime
    let spec: VisualSpec
    let data: VisualData
    let language: ScriptLanguage
    let interactive: Bool
    @AppStorage(AppSettings.Key.allowScripts.rawValue) private var allowScripts = false

    var body: some View {
        GeometryReader { geo in
            let job = job(for: geo.size)
            content(job)
                .frame(width: geo.size.width, height: geo.size.height)
                .task(id: "\(job?.key ?? 0)-\(runtime.runs[spec.id] ?? 0)") {
                    guard let job, interactive, allowScripts else { return }
                    // Wait for a resize or a burst of edits to settle before starting an interpreter.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    runtime.request(job, for: spec.id)
                }
        }
    }

    /// The run for this size; nil while the visual has no fields or no script.
    private func job(for size: CGSize) -> ScriptJob? {
        let script = spec.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty, !spec.fields(.values).isEmpty, size.width >= 40, size.height >= 40 else { return nil }
        // Sizes are rounded so that a few points of resizing reuse the plot.
        func round(_ v: CGFloat) -> Int { Int((v / 10).rounded()) * 10 }
        return ScriptJob(language: language, script: spec.content, dataset: VisualExport.captioned(data),
                         width: round(size.width), height: round(size.height))
    }

    @ViewBuilder private func content(_ job: ScriptJob?) -> some View {
        let name = "\(language.rawValue) visual"
        if spec.fields(.values).isEmpty {
            EmptyState(systemImage: "chevron.left.forwardslash.chevron.right", title: name,
                       message: "Add fields to Values: they reach the script as a data frame named dataset.")
        } else if spec.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyState(systemImage: "chevron.left.forwardslash.chevron.right", title: name,
                       message: "Write a \(language.rawValue) script in the script editor under the canvas, then run it.")
        } else if !allowScripts {
            EmptyState(systemImage: "lock", title: name, message: ScriptVisuals.turnedOff(language))
        } else if let entry = runtime.entry(spec.id) {
            switch entry.state {
            case .drawn(let png):
                plot(png)
            case .running:
                ZStack {
                    if let last = entry.lastImage { plot(last).opacity(0.4) }
                    ProgressView().controlSize(.small).help("Running the \(language.rawValue) script")
                }
            case .failed(let message):
                EmptyState(systemImage: "exclamationmark.triangle", title: "Can't display this visual", message: message)
                    .textSelection(.enabled)
            }
        } else if job == nil || !interactive {
            EmptyState(systemImage: "chevron.left.forwardslash.chevron.right", title: name,
                       message: interactive ? "Make the visual larger to draw the plot." : "The plot is drawn when the page is shown.")
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private func plot(_ png: Data) -> some View {
        if let image = NSImage(data: png) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spec.altText.isEmpty ? "\(language.rawValue) visual plot" : spec.altText)
                .accessibilityAddTraits(.isImage)
        } else {
            EmptyState(systemImage: "exclamationmark.triangle", title: "Can't display this visual",
                       message: "The script's image couldn't be read.")
        }
    }
}

/// The script editor under the canvas while a Python or R visual is selected: the script, how
/// `dataset` is made, and Run (⌘↩). Edits are kept to the visual when it runs.
struct ScriptEditorPane: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    @ObservedObject var runtime: ScriptVisualRuntime
    @State private var draft = ""
    @State private var editing: UUID?

    var body: some View {
        let language = ScriptLanguage(spec.type) ?? .python
        VStack(spacing: 0) {
            HStack(spacing: Design.Space.s) {
                Text("\(language.rawValue) script editor").font(Design.Typeface.bodyStrong)
                Text(ScriptVisuals.preamble(language, columns: spec.fields(.values).map(\.caption)))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help("The fields in Values reach the script as the data frame dataset")
                Spacer(minLength: Design.Space.s)
                status(language)
                IconButton("play.fill", help: "Run the \(language.rawValue) script (⌘↩)") { run() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.xs)
            Hairline()
            CodeEditor(text: $draft, language: language == .python ? LanguageSupport.python : ScriptVisuals.rLanguage,
                       fontSize: 12, showsLineNumbers: true, onCommit: run)
        }
        .background(Design.Palette.surface)
        .onAppear(perform: load)
        .onChange(of: spec.id) { _, _ in load() }
    }

    private func load() {
        draft = spec.content
        editing = spec.id
    }

    @ViewBuilder private func status(_ language: ScriptLanguage) -> some View {
        if draft != spec.content {
            Text("Not run yet").font(Design.Typeface.caption).foregroundStyle(.secondary)
        } else if let entry = runtime.entry(spec.id) {
            switch entry.state {
            case .running:
                ProgressView().controlSize(.mini)
                Text("Running…").font(Design.Typeface.caption).foregroundStyle(.secondary)
            case .drawn:
                Text("Drawn in \(Self.seconds(entry.milliseconds))").font(Design.Typeface.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text("Failed").font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative)
                    .help(message)
            }
        }
    }

    static func seconds(_ ms: Double) -> String { String(format: "%.1f s", ms / 1000) }

    /// Keeps the script on the visual (one undo step) and runs it, even when it did not change.
    private func run() {
        guard editing == spec.id else { return }
        if draft != spec.content {
            let text = draft
            store.updateVisuals([spec.id], name: "Edit Script") { $0.content = text }
        } else {
            runtime.runAgain(spec.id)
        }
    }
}
