import SwiftUI
import FacetCore
import FacetDesign

/// Input slicer: an operator menu, a text field that accepts typed or pasted lists, and chips of the
/// applied values.
///
/// Writes `SlicerState.selected` (the applied values) and mirrors them newline-joined in
/// `SlicerState.text`. The operator is a spec setting: `format["slicer"]["operator"]`, persisted
/// through `onSpecChange`. `CmpSlInputMatcher` implements the matching semantics.
struct CmpSlInputView: View {
    let session: CmpSlSession
    let size: CGSize
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let env = session.env, cfg = session.cfg
        let opID = env.f.string("slicer", "operator", "contains")
        let op = CmpSlLogic.inputOperators.first { $0.id == opID } ?? CmpSlLogic.inputOperators[0]
        let terms = session.state.selected
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if env.f.bool("slicer", "showOperator", true), size.width >= 150 {
                    CmpSlMenu(title: op.label, options: CmpSlLogic.inputOperators.map { ($0.id, $0.label) },
                              env: env, cfg: cfg, accessibility: "Operator") { id in
                        env.update { $0.setFmt("slicer", "operator", .string(id)) }
                        // Comparison operators take one value.
                        if CmpSlLogic.inputOperators.first(where: { $0.id == id })?.single == true, terms.count > 1 {
                            write(Array(terms.prefix(1)))
                        }
                    }
                }
                HStack(spacing: 5) {
                    TextField("", text: $draft,
                              prompt: Text(env.f.string("slicer", "placeholder", op.single ? "Type a value" : "Type or paste values"))
                                  .foregroundColor(env.secondary.opacity(0.85)))
                        .textFieldStyle(.plain)
                        .font(env.font(cfg.fontSize))
                        .foregroundStyle(cfg.text)
                        .focused($focused)
                        .onSubmit { commitDraft(single: op.single) }
                        .onChange(of: draft) { _, new in
                            // A paste containing line breaks or tabs is a list: apply it immediately.
                            if new.contains("\n") || new.contains("\t") { commitDraft(single: op.single) }
                        }
                        .accessibilityLabel("\(op.label) value")
                    if !draft.isEmpty || !terms.isEmpty {
                        Button { draft = ""; write([]) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(env.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear")
                        .accessibilityLabel("Clear all values")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(CmpSlFieldBackground(env: env, focused: focused))
            }
            if !terms.isEmpty, size.height >= 54 {
                ScrollView(.vertical) {
                    CmpSlFlow(spacing: 5) {
                        ForEach(Array(terms.enumerated()), id: \.offset) { _, t in
                            chip(t, env: env, cfg: cfg)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Applied values")
            }
        }
    }

    private func chip(_ term: Value, env: CmpEnv, cfg: CmpSlConfig) -> some View {
        let label = term.asString
        return HStack(spacing: 4) {
            Text(label).font(env.font(max(10, cfg.fontSize - 1), .medium)).foregroundStyle(cfg.text).lineLimit(1)
            Button { write(session.state.selected.filter { $0 != term }) } label: {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(env.secondary)
                    .frame(width: 12, height: 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(label)")
        }
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 3)
        .background(Capsule().fill(env.selectionFill))
        .overlay(Capsule().strokeBorder(env.theme.isHighContrast ? env.grid : .clear, lineWidth: 1))
        .help(label)
    }

    private func commitDraft(single: Bool) {
        let parts = CmpSlLogic.parseList(draft)
        guard !parts.isEmpty else { draft = ""; return }
        let col = session.env.data.indices(.field).first
        let numeric = col.flatMap { session.env.data.table.columns[safe: $0]?.type.isNumeric } ?? false
        let values = parts.map { CmpSlLogic.typedValue($0, numeric: numeric) }
        write(CmpSlInputView.merged(existing: session.state.selected, new: values, single: single))
        draft = ""
    }

    /// Applied values after adding `new`: single-value operators replace; lists append without duplicates.
    static func merged(existing: [Value], new: [Value], single: Bool) -> [Value] {
        if single { return Array(new.suffix(1)) }
        var out = existing
        for v in new where !out.contains(v) { out.append(v) }
        return out
    }

    private func write(_ values: [Value]) {
        session.update {
            $0.selected = values
            $0.text = values.map(\.asString).joined(separator: "\n")
        }
    }
}
