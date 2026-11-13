import SwiftUI
import FacetCore
import FacetDesign

// MARK: - Model

/// A styled run of inline text.
struct CmpRichRun: Equatable {
    var text: String
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var superscript = false
    var `subscript` = false
    var link: String?
    /// True for a `{{placeholder}}` that could not be resolved from the data (drawn as a quiet token).
    var unresolved = false
}

enum CmpRichBlock: Equatable {
    case heading(level: Int, runs: [CmpRichRun])
    case paragraph(runs: [CmpRichRun])
    case bullet(indent: Int, runs: [CmpRichRun])
    case numbered(indent: Int, number: Int, runs: [CmpRichRun])
    case spacer
}

/// Parser for the text-box Markdown subset:
/// `# / ## / ###` headings, `**bold**`, `*italic*` / `_italic_`, `<u>underline</u>`, `~~strike~~`,
/// `[text](url)`, `- ` / `* ` bullets, `1. ` numbered lists (two spaces of indent per level),
/// `^superscript^`, `~subscript~`, `<br>`, backslash escapes, and `{{Name}}` / `{{=DAX}}` dynamic values.
enum CmpRichText {
    /// `resolve` maps a placeholder body (e.g. "Total Sales" or "=SUM(Sales[Amount])") to display text.
    static func parse(_ source: String, resolve: (String) -> String? = { _ in nil }) -> [CmpRichBlock] {
        var blocks: [CmpRichBlock] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(runs: inline(paragraph.joined(separator: "\n"), resolve: resolve)))
            paragraph = []
        }
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let indentChars = raw.prefix { $0 == " " || $0 == "\t" }
            let indent = indentChars.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
            let line = raw.dropFirst(indentChars.count)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                if let last = blocks.last, last != .spacer { blocks.append(.spacer) }
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let rest = line.dropFirst(level)
                if level <= 3, rest.hasPrefix(" ") {
                    flush()
                    blocks.append(.heading(level: level, runs: inline(String(rest.dropFirst()), resolve: resolve)))
                    continue
                }
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                blocks.append(.bullet(indent: indent, runs: inline(String(line.dropFirst(2)), resolve: resolve)))
                continue
            }
            let digits = line.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 4, line.dropFirst(digits.count).hasPrefix(". "), let n = Int(digits) {
                flush()
                blocks.append(.numbered(indent: indent, number: n, runs: inline(String(line.dropFirst(digits.count + 2)), resolve: resolve)))
                continue
            }
            paragraph.append(String(line))
        }
        flush()
        while blocks.last == .spacer { blocks.removeLast() }
        return blocks
    }

    /// Inline parser. Markers only open when a matching closer exists later in the text, so "2 * 3" stays literal.
    static func inline(_ source: String, resolve: (String) -> String? = { _ in nil }, base: CmpRichRun = CmpRichRun(text: "")) -> [CmpRichRun] {
        var runs: [CmpRichRun] = []
        var style = base
        var buffer = ""
        let chars = Array(source)
        var i = 0
        func emit() {
            guard !buffer.isEmpty else { return }
            var r = style; r.text = buffer
            if var last = runs.last, sameStyle(last, r) { last.text += buffer; runs[runs.count - 1] = last } else { runs.append(r) }
            buffer = ""
        }
        func has(_ s: String, at k: Int) -> Bool {
            let a = Array(s)
            guard k + a.count <= chars.count else { return false }
            for j in 0..<a.count where chars[k + j] != a[j] { return false }
            return true
        }
        func find(_ s: String, from k: Int) -> Int? {
            var j = k
            while j < chars.count { if has(s, at: j) { return j }; j += 1 }
            return nil
        }
        func isWord(_ k: Int) -> Bool { k >= 0 && k < chars.count && (chars[k].isLetter || chars[k].isNumber) }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count { buffer.append(chars[i + 1]); i += 2; continue }
            if has("{{", at: i), let end = find("}}", from: i + 2) {
                let name = String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespaces)
                emit()
                var r = style
                if let value = resolve(name) { r.text = value } else { r.text = "{{\(name)}}"; r.unresolved = true }
                runs.append(r)
                i = end + 2; continue
            }
            if has("<br>", at: i) || has("<br/>", at: i) { buffer.append("\n"); i += has("<br>", at: i) ? 4 : 5; continue }
            if has("<u>", at: i), !style.underline, find("</u>", from: i + 3) != nil { emit(); style.underline = true; i += 3; continue }
            if has("</u>", at: i), style.underline { emit(); style.underline = false; i += 4; continue }
            if has("**", at: i) {
                if style.bold { emit(); style.bold = false; i += 2; continue }
                if find("**", from: i + 2) != nil { emit(); style.bold = true; i += 2; continue }
            }
            if has("~~", at: i) {
                if style.strike { emit(); style.strike = false; i += 2; continue }
                if find("~~", from: i + 2) != nil { emit(); style.strike = true; i += 2; continue }
            }
            if c == "*" || c == "_" {
                let wordBound = c == "*" || (style.italic ? !isWord(i + 1) : !isWord(i - 1))
                if wordBound {
                    if style.italic { emit(); style.italic = false; i += 1; continue }
                    if i + 1 < chars.count, chars[i + 1] != " ", let close = find(String(c), from: i + 1), close > i + 1 {
                        emit(); style.italic = true; i += 1; continue
                    }
                }
            }
            if c == "^" || c == "~" {
                let isSup = c == "^"
                let active = isSup ? style.superscript : style.subscript
                if active { emit(); if isSup { style.superscript = false } else { style.subscript = false }; i += 1; continue }
                // The closer must come before any whitespace: H~2~O, x^2^.
                var j = i + 1
                while j < chars.count, chars[j] != c, !chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == c, j > i + 1 {
                    emit(); if isSup { style.superscript = true } else { style.subscript = true }; i += 1; continue
                }
            }
            if c == "[", let mid = find("](", from: i + 1), let end = find(")", from: mid + 2),
               !chars[(i + 1)..<mid].contains("\n") {
                emit()
                var linkStyle = style
                linkStyle.link = String(chars[(mid + 2)..<end]).trimmingCharacters(in: .whitespaces)
                runs.append(contentsOf: inline(String(chars[(i + 1)..<mid]), resolve: resolve, base: linkStyle))
                i = end + 1; continue
            }
            buffer.append(c); i += 1
        }
        emit()
        return runs
    }

    private static func sameStyle(_ a: CmpRichRun, _ b: CmpRichRun) -> Bool {
        var x = a, y = b
        x.text = ""; y.text = ""
        return x == y && !a.unresolved
    }
}

/// Text edits behind the formatting bar (pure, so they can be checked without a view).
enum CmpRichEdit {
    /// Wraps `range` of `text` in `pre`…`post` (inserting `placeholder` when the range is empty).
    static func wrap(_ text: String, range: Range<String.Index>, pre: String, post: String, placeholder: String) -> String {
        var t = text
        let inner = range.isEmpty ? placeholder : String(text[range])
        t.replaceSubrange(range, with: pre + inner + post)
        return t
    }

    /// Sets the line prefix ("- ", "1. ", "# ", …; "" clears) on every line touched by `range`,
    /// replacing any existing heading / list prefix. Numbered lists count up from 1.
    static func setLinePrefix(_ text: String, range: Range<String.Index>, prefix: String) -> String {
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        var offset = 0, number = 1
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            let start = offset, end = offset + line.count
            offset = end + 1
            guard end >= lower, start <= upper else { out.append(line); continue }
            var body = Substring(line)
            if body.hasPrefix("#") {
                let hashes = body.prefix { $0 == "#" }.count
                if body.dropFirst(hashes).hasPrefix(" ") { body = body.dropFirst(hashes + 1) }
            } else if body.hasPrefix("- ") || body.hasPrefix("* ") {
                body = body.dropFirst(2)
            } else {
                let digits = body.prefix { $0.isNumber }
                if !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". ") { body = body.dropFirst(digits.count + 2) }
            }
            if prefix == "1. " { out.append("\(number). " + body); number += 1 } else { out.append(prefix + body) }
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Rendering

struct CmpRichTextStyle {
    var size: Double
    var color: Color
    var linkColor: Color
    var tokenColor: Color
    var family: String
    var lineSpacing: Double
    var alignment: String

    func font(_ size: Double, bold: Bool, italic: Bool) -> Font {
        var f: Font = family.isEmpty ? .system(size: size, weight: bold ? .semibold : .regular)
            : .custom(family, size: size).weight(bold ? .semibold : .regular)
        if italic { f = f.italic() }
        return f
    }

    func attributed(_ runs: [CmpRichRun], size: Double, bold: Bool = false) -> AttributedString {
        var out = AttributedString()
        for r in runs {
            var a = AttributedString(r.text)
            let script = r.superscript || r.subscript
            let s = script ? size * 0.68 : size
            a.font = r.unresolved ? Font.system(size: s * 0.92, design: .monospaced) : font(s, bold: bold || r.bold, italic: r.italic)
            a.foregroundColor = r.unresolved ? tokenColor : (r.link != nil ? linkColor : color)
            if r.unresolved { a.backgroundColor = tokenColor.opacity(0.12) }
            if r.underline || r.link != nil { a.underlineStyle = .single }
            if r.strike { a.strikethroughStyle = .single }
            if r.superscript { a.baselineOffset = size * 0.36 }
            if r.subscript { a.baselineOffset = -size * 0.16 }
            if let link = r.link, let url = URL(string: link), let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme) { a.link = url }
            out.append(a)
        }
        return out
    }
}

struct CmpRichTextBody: View {
    let blocks: [CmpRichBlock]
    let style: CmpRichTextStyle

    var body: some View {
        let h: HorizontalAlignment = style.alignment == "center" ? .center : (style.alignment == "right" ? .trailing : .leading)
        let t: TextAlignment = style.alignment == "center" ? .center : (style.alignment == "right" ? .trailing : .leading)
        VStack(alignment: h, spacing: style.size * 0.38) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let runs):
                    let scale = level == 1 ? 1.7 : (level == 2 ? 1.36 : 1.14)
                    Text(style.attributed(runs, size: style.size * scale, bold: true))
                        .multilineTextAlignment(t).padding(.top, level == 1 ? 0 : style.size * 0.15)
                        .accessibilityAddTraits(.isHeader)
                case .paragraph(let runs):
                    Text(style.attributed(runs, size: style.size)).multilineTextAlignment(t)
                case .bullet(let indent, let runs):
                    listRow(marker: indent % 2 == 0 ? "•" : "◦", indent: indent, runs: runs)
                case .numbered(let indent, let number, let runs):
                    listRow(marker: "\(number).", indent: indent, runs: runs)
                case .spacer:
                    Color.clear.frame(height: style.size * 0.3)
                }
            }
        }
        .lineSpacing(style.lineSpacing)
        .tint(style.linkColor)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: h, vertical: .top))
    }

    private func listRow(marker: String, indent: Int, runs: [CmpRichRun]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: style.size * 0.45) {
            Text(marker).font(style.font(style.size, bold: false, italic: false)).foregroundStyle(style.color.opacity(0.75))
                .monospacedDigit()
                .frame(minWidth: style.size * 1.1, alignment: .trailing)
            Text(style.attributed(runs, size: style.size)).multilineTextAlignment(.leading)
        }
        .padding(.leading, CGFloat(indent) * style.size * 1.4)
        .frame(maxWidth: style.alignment == "left" ? .infinity : nil, alignment: .leading)
    }
}

// MARK: - Text box visual

struct CmpTextBoxView: View {
    let env: CmpEnv
    var startEditing = false
    @State private var editing = false
    @State private var draft = ""
    @State private var selection: TextSelection?

    var body: some View {
        Group {
            if editing || startEditing { editor } else { reader }
        }
        .onAppear { if startEditing { draft = env.spec.content } }
    }

    private var style: CmpRichTextStyle {
        let f = env.f
        return CmpRichTextStyle(size: f.double("text", "size", 13), color: f.color("text", "color", env.theme.foreground),
                                linkColor: f.color("text", "linkColor", env.theme.accent), tokenColor: env.theme.accentColor,
                                family: f.string("text", "fontFamily", env.theme.label.fontFamily),
                                lineSpacing: f.double("text", "lineSpacing", 2), alignment: f.string("text", "alignment", "left"))
    }

    /// Dynamic value lookup: a data column whose caption or name equals the placeholder (case-insensitive);
    /// `{{=DAX}}` matches a column named "=DAX" or "DAX".
    static func resolve(_ name: String, env: CmpEnv) -> String? {
        guard env.data.table.rowCount > 0 else { return nil }
        let candidates = name.hasPrefix("=") ? [name, String(name.dropFirst()).trimmingCharacters(in: .whitespaces)] : [name]
        for c in env.data.table.columns.indices {
            let names = [env.caption(c), env.data.table.columns[c].name]
            if names.contains(where: { n in candidates.contains { $0.caseInsensitiveCompare(n) == .orderedSame } }) {
                let s = env.data.formatted(row: 0, col: c)
                return s.isEmpty ? "(Blank)" : s
            }
        }
        return nil
    }

    @ViewBuilder private var reader: some View {
        if env.spec.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CmpPlaceholder(systemImage: "text.alignleft", title: "Text box", message: "Double-click to add text.", theme: env.theme)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginEditing() }
        } else {
            let blocks = CmpRichText.parse(env.spec.content) { Self.resolve($0, env: env) }
            let content = CmpRichTextBody(blocks: blocks, style: style)
            let vertical: Alignment = {
                switch env.f.string("text", "verticalAlignment", "top") {
                case "middle": return .center
                case "bottom": return .bottom
                default: return .top
                }
            }()
            ViewThatFits(in: .vertical) {
                content.frame(maxHeight: .infinity, alignment: vertical)
                ScrollView(.vertical) { content }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { beginEditing() }
            .accessibilityElement(children: .contain)
        }
    }

    private func beginEditing() {
        guard env.isInteractive else { return }
        draft = env.spec.content
        editing = true
    }
    private func commit() {
        guard editing || startEditing else { return }
        editing = false
        if draft != env.spec.content { env.update { $0.content = draft } }
    }

    private var currentRange: Range<String.Index> {
        if let selection, case .selection(let r) = selection.indices,
           r.lowerBound >= draft.startIndex, r.upperBound <= draft.endIndex { return r }
        return draft.endIndex..<draft.endIndex
    }
    private func wrap(_ pre: String, _ post: String, _ placeholder: String) {
        draft = CmpRichEdit.wrap(draft, range: currentRange, pre: pre, post: post, placeholder: placeholder)
        selection = nil
    }
    private func linePrefix(_ prefix: String) {
        draft = CmpRichEdit.setLinePrefix(draft, range: currentRange, prefix: prefix)
        selection = nil
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    Menu {
                        Button("Title") { linePrefix("# ") }
                        Button("Heading") { linePrefix("## ") }
                        Button("Subheading") { linePrefix("### ") }
                        Button("Body") { linePrefix("") }
                    } label: { Image(systemName: "textformat.size") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 24)
                        .help("Paragraph style").accessibilityLabel("Paragraph style")
                    tool("bold", "Bold (⌘B)") { wrap("**", "**", "bold text") }.keyboardShortcut("b", modifiers: .command)
                    tool("italic", "Italic (⌘I)") { wrap("*", "*", "italic text") }.keyboardShortcut("i", modifiers: .command)
                    tool("underline", "Underline (⌘U)") { wrap("<u>", "</u>", "underlined text") }.keyboardShortcut("u", modifiers: .command)
                    tool("strikethrough", "Strikethrough") { wrap("~~", "~~", "text") }
                    divider
                    tool("list.bullet", "Bulleted list") { linePrefix("- ") }
                    tool("list.number", "Numbered list") { linePrefix("1. ") }
                    divider
                    tool("textformat.superscript", "Superscript") { wrap("^", "^", "2") }
                    tool("textformat.subscript", "Subscript") { wrap("~", "~", "2") }
                    tool("link", "Link (⌘K)") { wrap("[", "](https://)", "link text") }.keyboardShortcut("k", modifiers: .command)
                    Menu {
                        ForEach(env.data.table.columns.indices, id: \.self) { c in
                            Button(env.caption(c)) { wrap("{{\(env.caption(c))", "}}", "") }
                        }
                        if env.data.table.columnCount > 0 { Divider() }
                        Button("Measure placeholder") { wrap("{{", "}}", "Measure Name") }
                        Button("DAX expression") { wrap("{{=", "}}", "SUM(Table[Column])") }
                    } label: { Image(systemName: "curlybraces") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 24)
                        .help("Insert dynamic value").accessibilityLabel("Insert dynamic value")
                    Spacer(minLength: 8)
                    Button("Done") { commit() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(env.accent)
                        .padding(.horizontal, 6)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Finish editing (⌘↩). Esc cancels.")
                }
                .padding(.horizontal, 4).frame(height: 30)
            }
            .background(env.subtleFill)
            Rectangle().fill(env.grid).frame(height: 1)
            TextEditor(text: $draft, selection: $selection)
                .font(.system(size: max(11, style.size), design: .monospaced))
                .foregroundStyle(env.fg)
                .scrollContentBackground(.hidden)
                .padding(4)
                .accessibilityLabel("Text box source")
        }
        .background(env.card)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(env.accent.opacity(0.7), lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onExitCommand { editing = false }
        .onDisappear { commit() }
    }

    private var divider: some View { Rectangle().fill(env.grid).frame(width: 1, height: 14).padding(.horizontal, 3) }

    private func tool(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(env.fg.opacity(0.85))
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}
