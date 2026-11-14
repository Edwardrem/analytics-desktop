import SwiftUI
import FacetCore
import FacetDesign

// MARK: - Narrative values

/// A dynamic value in the narrative's kept text: it shows a Values-well field's current value, in the field's own
/// format or one the author picks, so the sentence stays right as filters change. The text holds
/// "{{value:<id>}}" where the value goes; the definitions are stored beside it on the visual.
struct NarrativeValue: Codable, Hashable, Identifiable {
    var id = UUID()
    var field: FieldRef
    /// A format string, or empty for the field's own format.
    var format = ""
    /// The value as it was written, shown when the field has left the Values well.
    var written: String
}

@MainActor
enum NarrativeValues {
    /// The formats a value can be switched to; the empty format is the field's own.
    static let formats: [(label: String, format: String)] = [
        ("Field's format", ""), ("Whole number", "#,0"), ("Two decimals", "#,0.00"), ("Percent", "0.0%"),
        ("Currency", "$#,0"), ("Currency with cents", "$#,0.00"), ("Thousands", "#,0.0,\"K\""), ("Millions", "#,0.0,,\"M\""),
    ]

    /// Values whose text is shorter than this are not turned into tokens: a lone digit matches too much prose.
    nonisolated static let minimumTokenLength = 2
    nonisolated static let linkScheme = "narrative-value"

    // MARK: Stored definitions

    nonisolated static func values(_ spec: VisualSpec) -> [NarrativeValue] {
        let json = spec.fmtString("narrative", "values", "")
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([NarrativeValue].self, from: data) else { return [] }
        return values
    }

    nonisolated static func encoded(_ values: [NarrativeValue]) -> JSONValue? {
        guard !values.isEmpty, let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) else { return nil }
        return .string(json)
    }

    nonisolated static func token(_ id: UUID) -> String { "{{value:\(id.uuidString)}}" }

    // MARK: Pieces of the text

    enum Piece: Equatable {
        case text(String)
        case value(UUID)
    }

    /// The text split into prose and value tokens. A malformed token stays as text.
    nonisolated static func pieces(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var rest = Substring(text)
        while let open = rest.range(of: "{{value:") {
            guard let close = rest[open.upperBound...].range(of: "}}"),
                  let id = UUID(uuidString: String(rest[open.upperBound..<close.lowerBound])) else {
                out.append(.text(String(rest[..<open.upperBound])))
                rest = rest[open.upperBound...]
                continue
            }
            if open.lowerBound > rest.startIndex { out.append(.text(String(rest[..<open.lowerBound]))) }
            out.append(.value(id))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        // Merge neighbouring prose so equal texts compare equal.
        return out.reduce(into: []) { acc, p in
            if case .text(let b) = p, case .text(let a)? = acc.last { acc[acc.count - 1] = .text(a + b) } else { acc.append(p) }
        }
    }

    // MARK: Current values

    /// The Values well's fields with what each shows now, in well order.
    nonisolated static func current(_ spec: VisualSpec, data: VisualData) -> [(field: FieldRef, value: Value, format: String)] {
        guard data.error == nil, data.table.rowCount > 0 else { return [] }
        let wells = spec.fields(.values)
        return data.indices(.values).enumerated().compactMap { n, col in
            guard let field = wells[safe: n], col < data.table.columnCount else { return nil }
            return (field, data.table[0, col], data.formats[safe: col] ?? "")
        }
    }

    /// What a value token shows now: its field's current value in its format, or what was written when the field
    /// is no longer in the Values well.
    nonisolated static func display(_ value: NarrativeValue, spec: VisualSpec, data: VisualData) -> (text: String, isLive: Bool) {
        guard let hit = current(spec, data: data).first(where: { $0.field.key == value.field.key }) else { return (value.written, false) }
        return (ValueFormatter.format(hit.value, value.format.isEmpty ? hit.format : value.format), true)
    }

    /// The text with each token replaced by what it shows now.
    nonisolated static func plain(_ text: String, spec: VisualSpec, data: VisualData) -> String {
        let defs = values(spec)
        return pieces(text).map { piece -> String in
            switch piece {
            case .text(let t): return t
            case .value(let id): return defs.first { $0.id == id }.map { display($0, spec: spec, data: data).text } ?? ""
            }
        }.joined()
    }

    // MARK: Writing tokens

    /// Turns each Values-well value the text quotes (as the visual formats it, standing alone rather than inside a
    /// longer number) into a token. A field that had a token before keeps its id and chosen format.
    nonisolated static func tokenize(_ text: String, spec: VisualSpec, data: VisualData,
                                     previous: [NarrativeValue] = []) -> (text: String, values: [NarrativeValue]) {
        var result = text
        var values: [NarrativeValue] = []
        for hit in current(spec, data: data) {
            let shown = ValueFormatter.format(hit.value, hit.format)
            guard shown.count >= minimumTokenLength else { continue }
            let ranges = standaloneRanges(of: shown, in: result)
            guard !ranges.isEmpty else { continue }
            var value = previous.first { $0.field.key == hit.field.key } ?? NarrativeValue(field: hit.field, written: shown)
            value.written = shown
            let token = token(value.id)
            for r in ranges.reversed() { result.replaceSubrange(r, with: token) }
            values.append(value)
        }
        return (result, values)
    }

    /// Where `needle` occurs in `text` with no letter, digit or token brace beside it, and not as part of a
    /// longer number such as "1,150" or "150.5".
    nonisolated static func standaloneRanges(of needle: String, in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "{" || c == "}" }
        while from < text.endIndex, let r = text.range(of: needle, range: from..<text.endIndex) {
            from = r.upperBound
            if r.lowerBound > text.startIndex {
                let before = text[text.index(before: r.lowerBound)]
                if isWord(before) { continue }
                if before == "," || before == ".", text.index(before: r.lowerBound) > text.startIndex,
                   text[text.index(before: text.index(before: r.lowerBound))].isNumber { continue }
            }
            if r.upperBound < text.endIndex {
                let after = text[r.upperBound]
                if isWord(after) { continue }
                let next = text.index(after: r.upperBound)
                if after == "," || after == ".", next < text.endIndex, text[next].isNumber { continue }
            }
            out.append(r)
        }
        return out
    }

    // MARK: Display

    /// The kept text for display: values in the accent colour and, when `editable`, links that open the value editor.
    nonisolated static func attributed(_ text: String, spec: VisualSpec, data: VisualData, editable: Bool) -> AttributedString {
        let defs = values(spec)
        var out = AttributedString()
        for piece in pieces(text) {
            switch piece {
            case .text(let t):
                out += AttributedString(t)
            case .value(let id):
                guard let def = defs.first(where: { $0.id == id }) else { continue }
                let shown = display(def, spec: spec, data: data)
                var run = AttributedString(shown.text)
                run.font = Design.Typeface.bodyStrong
                run.foregroundColor = shown.isLive ? Color.accentColor : Color.secondary
                if editable { run.link = URL(string: "\(linkScheme):\(id.uuidString)") }
                out += run
            }
        }
        return out
    }

    nonisolated static func valueID(from url: URL) -> UUID? {
        guard url.scheme == linkScheme else { return nil }
        return UUID(uuidString: url.absoluteString.dropFirst(linkScheme.count + 1).description)
    }

    // MARK: Editing

    /// Points a value at another field (added to the Values well when it isn't there) or another format, as one
    /// undoable change.
    static func change(_ valueID: UUID, field: FieldRef? = nil, format: String? = nil, visual id: UUID, store: DocumentStore) {
        guard let spec = store.visual(id) else { return }
        var defs = values(spec)
        guard let i = defs.firstIndex(where: { $0.id == valueID }) else { return }
        let addsField = field.map { f in !spec.fields(.values).contains { $0.key == f.key } } ?? false
        if let field { defs[i].field = field }
        if let format { defs[i].format = format }
        store.updateVisual(id, name: "Change Narrative Value", invalidates: addsField ? .visuals([id]) : .layout) { v in
            if addsField, let field { v.wells[Well.values.rawValue, default: []].append(field) }
            v.setFmt("narrative", "values", encoded(defs))
        }
    }

    /// Replaces a value's token with the text it shows now, so that part of the sentence stops updating.
    static func freeze(_ valueID: UUID, visual id: UUID, store: DocumentStore) {
        guard let spec = store.visual(id) else { return }
        var defs = values(spec)
        guard let def = defs.first(where: { $0.id == valueID }) else { return }
        let shown = display(def, spec: spec, data: store.visualData[id] ?? VisualData()).text
        let text = NarrativeAssistant.text(spec).replacingOccurrences(of: token(valueID), with: shown)
        defs.removeAll { $0.id == valueID }
        store.updateVisual(id, name: "Remove Narrative Value", invalidates: .layout) { v in
            v.setFmt("narrative", "text", .string(text))
            v.setFmt("narrative", "values", encoded(defs))
        }
    }

    /// The fields a value can show: those in the Values well, then the model's other visible measures.
    static func choices(_ spec: VisualSpec, model: SemanticModel) -> [FieldRef] {
        let well = spec.fields(.values)
        let measures = model.tables.filter { !$0.isHidden }.flatMap { t in
            t.measures.filter { !$0.isHidden }.map { FieldRef.measure(t.name, $0.name) }
        }
        return well + measures.filter { m in !well.contains { $0.key == m.key } }
    }
}

/// The popover a value token opens: which field it shows and in what format.
struct NarrativeValueEditor: View {
    let spec: VisualSpec
    let valueID: UUID
    let store: DocumentStore
    let dismiss: () -> Void

    var body: some View {
        let def = NarrativeValues.values(spec).first { $0.id == valueID }
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("Value").font(Design.Typeface.headline)
            if let def {
                let shown = NarrativeValues.display(def, spec: spec, data: store.visualData[spec.id] ?? VisualData())
                Text(shown.isLive ? "Shows \(shown.text) with the current filters." : "Its field is no longer in the Values well; it shows \(shown.text) as written.")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Field", selection: Binding(get: { def.field.key }, set: { key in
                    if let f = NarrativeValues.choices(spec, model: store.model).first(where: { $0.key == key }) {
                        NarrativeValues.change(valueID, field: f, visual: spec.id, store: store)
                    }
                })) {
                    ForEach(NarrativeValues.choices(spec, model: store.model), id: \.key) { Text($0.caption).tag($0.key) }
                    if !NarrativeValues.choices(spec, model: store.model).contains(where: { $0.key == def.field.key }) {
                        Text(def.field.caption).tag(def.field.key)
                    }
                }
                Picker("Format", selection: Binding(get: { def.format }, set: { NarrativeValues.change(valueID, format: $0, visual: spec.id, store: store) })) {
                    ForEach(NarrativeValues.formats, id: \.format) { Text($0.label).tag($0.format) }
                    if !NarrativeValues.formats.contains(where: { $0.format == def.format }) { Text(def.format).tag(def.format) }
                }
                Hairline()
                HStack {
                    Button("Use as Plain Text") {
                        NarrativeValues.freeze(valueID, visual: spec.id, store: store)
                        dismiss()
                    }
                    .help("Replace this value with the text it shows now, so it stops updating (you can undo it)")
                    Spacer()
                    Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
                }
            } else {
                Text("This value is no longer in the narrative.").font(Design.Typeface.body).foregroundStyle(.secondary)
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Space.m)
        .frame(width: 300)
    }
}
