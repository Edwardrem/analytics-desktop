import SwiftUI
import FacetCore
import FacetDesign

/// Measure descriptions written by the assistant (Copilot's "Create with Copilot" for a measure's Description):
/// the assistant reads the measure's DAX with the model as context, the author reviews the text, and Keep
/// stores it on the measure as one undoable change.
@MainActor
enum MeasureDescriptions {
    static let commandID = "assistant.describeMeasure"

    static let instructions = """
    Write the Description property of a DAX measure. Report authors read it in tooltips, and AI features use it \
    to understand the model. Write one or two plain sentences, at most 300 characters, saying what the measure \
    calculates in business terms, including any filters, time logic or conditions in the formula. No Markdown, \
    no quotation marks around the text, no DAX code, and do not start with "This measure".
    """

    static var command: AppCommand {
        AppCommand(id: commandID, title: "Generate Description with Assistant…", menu: .modeling, symbol: "sparkles",
                   help: "The assistant reads the measure's formula and suggests a description to review",
                   isEnabled: { ModelingTarget.measure($0) != nil }) { store in
            guard let (table, name) = ModelingTarget.measure(store) else { return }
            store.present { MeasureDescriptionSheet(table: table, measure: name) }
        }
    }

    /// The assistant's description of a measure, cleaned and checked.
    static func generate(table: String, measure name: String, store: DocumentStore) async throws -> String {
        guard let measure = store.model.table(table)?.measure(name) else { throw MeasureDescriptionError.missing(name) }
        var prompt = "Measure [\(measure.name)] in table '\(table)':\n\(measure.expression)\n"
        if !measure.formatString.isEmpty { prompt += "Format string: \(measure.formatString)\n" }
        if !measure.description.isEmpty { prompt += "Current description, to improve on: \(measure.description)\n" }
        prompt += "Write its description."
        let text = clean(try await AssistantTasks.ask(instructions, prompt: prompt, store: store))
        guard !text.isEmpty else { throw MeasureDescriptionError.unusable }
        return text
    }

    /// Plain description text: no code fences, no "Description:" label, no wrapping quotes, single spaces.
    nonisolated static func clean(_ answer: String) -> String {
        var text = answer.replacingOccurrences(of: "```", with: " ")
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for label in ["Description:", "description:"] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'")]
        for (open, close) in quotes where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Stores a description on the measure, if it still exists. Returns false when it was renamed or deleted.
    @discardableResult
    static func apply(_ text: String, table: String, measure name: String, store: DocumentStore) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, store.model.table(table)?.measure(name) != nil else { return false }
        ModelOps.updateMeasures(store, [(table, name)], name: "Generate Description", invalidates: .layout) { $0.description = value }
        return true
    }
}

enum MeasureDescriptionError: LocalizedError, Equatable {
    case missing(String)
    case unusable
    var errorDescription: String? {
        switch self {
        case .missing(let name): return "The measure \(name) is no longer in the model."
        case .unusable: return "The assistant's answer had no usable description. Try again."
        }
    }
}

/// The "Generate with assistant" link under a measure's Description in the properties panel.
struct MeasureDescriptionButton: View {
    @EnvironmentObject private var store: DocumentStore
    let table: String
    let measure: String

    var body: some View {
        Button {
            store.present { MeasureDescriptionSheet(table: table, measure: measure) }
        } label: {
            Label("Generate with assistant…", systemImage: "sparkles")
        }
        .buttonStyle(.link)
        .font(Design.Typeface.caption)
        .help("The assistant reads the measure's formula and suggests a description to review")
    }
}

/// Generate → review → Keep. The text stays editable before it is stored.
struct MeasureDescriptionSheet: View {
    @EnvironmentObject private var store: DocumentStore
    let table: String
    let measure: String
    @State private var draft = ""
    @State private var working = false
    @State private var failure: Error?
    @State private var configured = true

    private var current: String { store.model.table(table)?.measure(measure)?.description ?? "" }

    var body: some View {
        ModelingSheet(title: "Describe \(measure)",
                      subtitle: "The assistant reads the formula and the model, then suggests a description. Review it before you keep it.",
                      width: 460, height: nil) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                if !current.isEmpty {
                    VStack(alignment: .leading, spacing: Design.Space.xxs) {
                        SectionLabel("Current description")
                        Text(current).font(Design.Typeface.body).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let failure {
                    AssistantNotice(error: failure)
                } else if !configured {
                    AssistantNotice(message: AssistantTasks.setupMessage, showsSettings: true)
                }
                if working {
                    HStack(spacing: Design.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Writing a description…").font(Design.Typeface.body).foregroundStyle(.secondary)
                    }
                } else if draft.isEmpty, failure == nil, configured {
                    Text("Choose Generate to get a suggestion. Nothing is sent until you do.")
                        .font(Design.Typeface.caption).foregroundStyle(.secondary)
                } else if !draft.isEmpty {
                    VStack(alignment: .leading, spacing: Design.Space.xxs) {
                        SectionLabel("Suggested description")
                        TextEditor(text: $draft)
                            .font(Design.Typeface.body)
                            .frame(minHeight: 72, maxHeight: 140)
                            .scrollContentBackground(.hidden)
                            .padding(Design.Space.xs)
                            .background(RoundedRectangle(cornerRadius: Design.Radius.control).fill(Design.Palette.fill))
                    }
                }
            }
            .padding(Design.Space.l)
        } footer: {
            Button(draft.isEmpty ? "Generate" : "Try Again") { generate() }
                .disabled(working || !configured)
                .help("Ask the assistant for a description of this measure")
            Spacer()
            Button("Cancel") { store.dismissSheet() }.keyboardShortcut(.cancelAction)
            Button("Keep") {
                MeasureDescriptions.apply(draft, table: table, measure: measure, store: store)
                store.dismissSheet()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(working || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Store this text as the measure's description (you can undo it)")
        }
        .onAppear { configured = AssistantTasks.isConfigured }
        .onReceive(NotificationCenter.default.publisher(for: .assistantConfigurationChanged)) { _ in configured = AssistantTasks.isConfigured }
    }

    private func generate() {
        guard !working else { return }
        working = true
        failure = nil
        Task {
            do { draft = try await MeasureDescriptions.generate(table: table, measure: measure, store: store) }
            catch { failure = error }
            working = false
        }
    }
}
