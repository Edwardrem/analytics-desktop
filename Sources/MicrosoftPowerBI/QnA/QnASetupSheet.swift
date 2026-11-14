import SwiftUI
import FacetCore
import FacetAnalytics
import FacetDesign

/// The Q&A setup dialog (Modeling ▸ Q&A setup, or the gear in a Q&A visual): Teach Q&A and Review questions.
struct QnASetupSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case teach = "Teach Q&A", review = "Review questions"
        var id: String { rawValue }
    }

    @EnvironmentObject private var store: DocumentStore
    @State private var tab: Tab
    @State private var question: String
    @State private var values: [String: [Value]] = [:]

    init(tab: Tab = .teach, question: String = "") {
        _tab = State(initialValue: tab)
        _question = State(initialValue: question)
    }

    var body: some View {
        ModelingSheet(title: "Q&A setup",
                      subtitle: "Teach Q&A the words people use for your data, and review the questions asked in this file.",
                      width: 720, height: 560) {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
                .padding(.vertical, Design.Space.m)
                Hairline()
                switch tab {
                case .teach:
                    QnATeachView(question: $question, values: values)
                case .review:
                    QnAReviewView(values: values) { q in
                        question = q
                        tab = .teach
                    }
                }
            }
        } footer: {
            ModelingSheetButtons(cancelTitle: nil, confirmTitle: "Done")
        }
        .task { values = await QnASetupLogic.loadValues(store) }
    }
}

/// Review questions: what was asked in this file's Q&A visuals, and whether Q&A understands it now.
struct QnAReviewView: View {
    @EnvironmentObject private var store: DocumentStore
    let values: [String: [Value]]
    /// Opens Teach Q&A with the question.
    let teach: (String) -> Void
    @State private var onlyNeedingTeaching = false

    var body: some View {
        let all = QnASetupLogic.review(store.model, values: values)
        let shown = onlyNeedingTeaching ? all.filter(\.status.needsTeaching) : all
        VStack(spacing: 0) {
            HStack {
                Text(summary(all)).font(Design.Typeface.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Only questions that need teaching", isOn: $onlyNeedingTeaching)
                    .toggleStyle(.checkbox).font(Design.Typeface.caption)
                    .disabled(all.isEmpty)
            }
            .padding(.horizontal, Design.Space.l)
            .padding(.vertical, Design.Space.s)
            Hairline()
            if shown.isEmpty {
                EmptyState(systemImage: "questionmark.bubble",
                           title: all.isEmpty ? "No questions yet" : "Q&A understands every question",
                           message: all.isEmpty ? "Questions asked in this file's Q&A visuals appear here, with how Q&A answered them."
                                                : "Turn off the filter to see all the questions asked.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown) { review in
                            row(review)
                            Hairline()
                        }
                    }
                }
            }
        }
    }

    private func summary(_ all: [QnASetupLogic.Review]) -> String {
        guard !all.isEmpty else { return "No questions asked yet" }
        let needing = all.filter(\.status.needsTeaching).count
        return "\(all.count) question\(all.count == 1 ? "" : "s") asked · \(needing) need\(needing == 1 ? "s" : "") teaching"
    }

    private func row(_ review: QnASetupLogic.Review) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
            Image(systemName: symbol(review.status)).foregroundStyle(tint(review.status))
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                Text(review.record.question).font(Design.Typeface.bodyStrong).textSelection(.enabled)
                Text(detail(review.status)).font(Design.Typeface.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(asked(review.record)).font(Design.Typeface.caption).foregroundStyle(Design.Palette.tertiaryText)
            }
            Spacer(minLength: Design.Space.s)
            if review.status.needsTeaching {
                Button("Teach…") { teach(review.record.question) }
                    .controlSize(.small)
                    .help("Open Teach Q&A with this question to define the words it didn't understand")
            }
            IconButton("trash", help: "Remove this question from the list") {
                store.mutate("Remove Q&A Question", invalidates: .layout) { d in
                    QnASetupLogic.removeQuestion(review.record.id, in: &d.model)
                }
            }
        }
        .padding(.horizontal, Design.Space.l)
        .padding(.vertical, Design.Space.s)
    }

    private func symbol(_ status: QnASetupLogic.Status) -> String {
        switch status {
        case .verified: return "checkmark.seal.fill"
        case .understood: return "checkmark.circle"
        case .partly: return "exclamationmark.circle"
        case .notUnderstood: return "questionmark.circle"
        }
    }

    private func tint(_ status: QnASetupLogic.Status) -> Color {
        switch status {
        case .verified, .understood: return Design.Palette.positive
        case .partly: return Design.Palette.caution
        case .notUnderstood: return Design.Palette.negative
        }
    }

    private func detail(_ status: QnASetupLogic.Status) -> String {
        switch status {
        case .verified: return "Answered by a verified answer."
        case .understood(let text): return text
        case .partly(let words): return "Didn't understand: \(words.joined(separator: ", "))"
        case .notUnderstood(let words):
            return words.isEmpty ? "Nothing in this question matched the data." : "Didn't understand: \(words.joined(separator: ", "))"
        }
    }

    private func asked(_ record: QnAQuestionRecord) -> String {
        let when = record.lastAsked.formatted(date: .abbreviated, time: .shortened)
        return record.timesAsked == 1 ? "Asked \(when)" : "Asked \(record.timesAsked) times, last \(when)"
    }
}
