import SwiftUI
import FacetCore
import FacetDesign

/// Dynamic format strings for measures (Format ▸ Dynamic): a DAX expression, evaluated in each visual's
/// filter context, that returns the format string. The static format string stays as the fallback for
/// when the expression returns blank or fails.
enum DynamicFormat {
    /// A DAX text literal.
    static func literal(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    /// What the editor opens with: the measure's dynamic format, or, when it has none yet, its static
    /// format as a DAX string, so turning Dynamic on changes nothing until the expression is edited.
    static func initialExpression(for m: Measure) -> String { m.formatExpression ?? literal(m.formatString) }

    /// Sets a measure's dynamic format string; nil or blank text removes it.
    @MainActor static func set(_ store: DocumentStore, table: String, measure: String, expression: String?) {
        let value = expression.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        ModelOps.updateMeasures(store, [(table, measure)], name: value == nil ? "Remove Dynamic Format" : "Dynamic Format") {
            $0.formatExpression = value
        }
    }

    @MainActor static func edit(_ store: DocumentStore, table: String, measure: String) {
        guard let m = store.model.table(table)?.measure(measure) else { return }
        store.present { DynamicFormatSheet(table: table, measure: m.name, draft: initialExpression(for: m)) }
    }

    /// The expression as it evaluates outside any visual, for the preview: there the measure being
    /// formatted is simply the measure, so SELECTEDMEASURE(), SELECTEDMEASURENAME() and
    /// SELECTEDMEASUREFORMATSTRING() are replaced by its reference, name and static format.
    /// Text, quoted names, bracketed names and comments are left alone.
    static func previewExpression(_ expression: String, measure: Measure, reference: String) -> String {
        let replacements = [("SELECTEDMEASURENAME", literal(measure.name)),
                            ("SELECTEDMEASUREFORMATSTRING", literal(measure.formatString)),
                            ("SELECTEDMEASURE", reference)]
        let chars = Array(expression)
        var out = ""
        var i = 0
        func skip(to end: Character, doubled: Bool) {
            out.append(chars[i]); i += 1
            while i < chars.count {
                out.append(chars[i])
                if chars[i] == end {
                    if doubled, i + 1 < chars.count, chars[i + 1] == end { i += 1; out.append(chars[i]) } else { i += 1; return }
                }
                i += 1
            }
        }
        func startsWith(_ s: String, at j: Int) -> Bool {
            let t = Array(s)   // ASCII, upper-case
            guard j + t.count <= chars.count else { return false }
            return (0..<t.count).allSatisfy { String(chars[j + $0]).uppercased() == String(t[$0]) }
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { skip(to: "\"", doubled: true); continue }
            if c == "'" { skip(to: "'", doubled: true); continue }
            if c == "[" { skip(to: "]", doubled: true); continue }
            if startsWith("//", at: i) || startsWith("--", at: i) {
                while i < chars.count, chars[i] != "\n" { out.append(chars[i]); i += 1 }
                continue
            }
            if startsWith("/*", at: i) {
                while i < chars.count, !startsWith("*/", at: i) { out.append(chars[i]); i += 1 }
                if i < chars.count { out += "*/"; i += 2 }
                continue
            }
            let boundary = i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_" || chars[i - 1] == ".")
            if boundary, let (name, value) = replacements.first(where: { startsWith($0.0, at: i) }) {
                var j = i + name.count
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "(" {
                    j += 1
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                    if j < chars.count, chars[j] == ")" { out += value; i = j + 1; continue }
                }
            }
            out.append(c); i += 1
        }
        return out
    }
}

/// Edits a measure's dynamic format string, with live checking and a preview of the format it gives
/// outside any visual.
struct DynamicFormatSheet: View {
    @EnvironmentObject private var store: DocumentStore
    let table: String
    let measure: String
    @State var draft: String
    @State private var issues: [ExpressionIssue] = []
    @State private var preview: Preview?

    enum Preview: Equatable {
        case value(format: String, shown: String)
        case failed(String)
    }

    private var current: Measure? { store.model.table(table)?.measure(measure) }
    private var hasErrors: Bool { issues.contains { !$0.isWarning } }
    private var isBlank: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ModelingSheet(title: "Dynamic format string", subtitle: subtitle, width: 560, height: nil) {
            VStack(alignment: .leading, spacing: Design.Space.s) {
                CodeEditor(text: $draft, language: .dax, model: store.model, issues: issues, onCommit: apply, onCancel: { store.dismissSheet() })
                    .frame(height: 132)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(Design.Palette.elevated))
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                        .strokeBorder(hasErrors ? Design.Palette.negative.opacity(0.5) : Design.Palette.hairlineStrong))
                if let issue = issues.first {
                    Label(issue.message, systemImage: issue.isWarning ? "exclamationmark.triangle" : "exclamationmark.circle")
                        .font(Design.Typeface.caption)
                        .foregroundStyle(issue.isWarning ? Design.Palette.caution : Design.Palette.negative)
                        .lineLimit(2)
                }
                previewRow
            }
            .padding(Design.Space.l)
        } footer: {
            if current?.formatExpression != nil {
                Button("Use the static format") {
                    DynamicFormat.set(store, table: table, measure: measure, expression: nil)
                    store.dismissSheet()
                }
                .help("Remove the dynamic format string; the measure keeps its static format")
            }
            ModelingSheetButtons(confirmTitle: "Apply", confirmDisabled: isBlank || hasErrors, confirm: apply)
        }
        .task(id: draft) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await refresh()
        }
    }

    private var subtitle: String {
        "A DAX expression that returns the format string for [\(measure)], evaluated in each visual's filter context. "
            + "SELECTEDMEASURE() is the measure's value there. When it returns blank, the static format is used."
    }

    @ViewBuilder private var previewRow: some View {
        switch preview {
        case .value(let format, let shown):
            HStack(spacing: Design.Space.xs) {
                Text("Outside any visual:").foregroundStyle(.secondary)
                Text(shown).font(Design.Typeface.mono)
                Text(format.isEmpty ? "(general format)" : "with “\(format)”").foregroundStyle(.secondary).lineLimit(1)
            }
            .font(Design.Typeface.caption)
        case .failed(let message):
            Label("Preview: \(message)", systemImage: "eye.slash")
                .font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(2)
        case nil:
            EmptyView()
        }
    }

    private func refresh() async {
        guard let m = current, !isBlank else { issues = []; preview = nil; return }
        let text = draft, home = table
        let found = await store.withEngine { $0.check(text, kind: .measure, homeTable: home) }
        if Task.isCancelled { return }
        issues = found
        guard !found.contains(where: { !$0.isWarning }) else { preview = nil; return }
        let reference = ModelDAX.reference(.measure(table, m.name))
        let expression = DynamicFormat.previewExpression(text, measure: m, reference: reference)
        let fallback = m.formatString
        let result: Preview = await store.withEngine { engine in
            do {
                let format = try engine.scalar(expression, filters: [])
                let value = try engine.scalar(reference, filters: [])
                let f = format.isNull ? fallback : format.asString
                return .value(format: f, shown: value.isNull ? "(Blank)" : ValueFormatter.format(value, f))
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        if !Task.isCancelled { preview = result }
    }

    private func apply() {
        guard !isBlank, !hasErrors else { return }
        DynamicFormat.set(store, table: table, measure: measure, expression: draft)
        store.dismissSheet()
    }
}
