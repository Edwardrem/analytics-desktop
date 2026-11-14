import SwiftUI
import FacetDesign

/// The block structure of release notes in GitHub-flavoured Markdown: headings, paragraphs, bullet and
/// numbered lists, quotes, fenced code and rules. Inline styling (bold, italics, code, links) is left to
/// `AttributedString(markdown:)`.
enum MarkdownBlocks {
    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, depth: Int)
        case numbered(String, String, depth: Int)
        case quote(String)
        case code(String)
        case rule
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if let c = code { blocks.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            let depth = (raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }) / 2
            if let h = heading(line) { flush(); blocks.append(h); continue }
            if line == "---" || line == "***" || line == "___" { flush(); blocks.append(.rule); continue }
            if let rest = dropPrefix(line, ["- ", "* ", "+ "]) { flush(); blocks.append(.bullet(rest, depth: depth)); continue }
            if let (n, rest) = numbered(line) { flush(); blocks.append(.numbered(n, rest, depth: depth)); continue }
            if line.hasPrefix(">") { flush(); blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            paragraph.append(line)
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(hashes, line.dropFirst(hashes).trimmingCharacters(in: CharacterSet(charactersIn: " #")))
    }

    private static func dropPrefix(_ line: String, _ markers: [String]) -> String? {
        markers.first { line.hasPrefix($0) }.map { String(line.dropFirst($0.count)) }
    }

    private static func numbered(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (String(digits), String(rest.dropFirst(2)))
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                               failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
    }
}

/// Release notes rendered with the app's type scale.
struct ReleaseNotesView: View {
    let markdown: String

    var body: some View {
        let blocks = MarkdownBlocks.parse(markdown)
        VStack(alignment: .leading, spacing: Design.Space.s) {
            if blocks.isEmpty {
                Text("No notes were published for this version.").font(Design.Typeface.body).foregroundStyle(.secondary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in row(block) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func row(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownBlocks.inline(text))
                .font(level <= 2 ? Design.Typeface.headline : Design.Typeface.bodyStrong)
                .padding(.top, Design.Space.xs)
        case .paragraph(let text):
            Text(MarkdownBlocks.inline(text)).font(Design.Typeface.body).fixedSize(horizontal: false, vertical: true)
        case .bullet(let text, let depth):
            listRow("•", text, depth)
        case .numbered(let n, let text, let depth):
            listRow("\(n).", text, depth)
        case .quote(let text):
            HStack(alignment: .top, spacing: Design.Space.s) {
                Rectangle().fill(Design.Palette.hairlineStrong).frame(width: 2)
                Text(MarkdownBlocks.inline(text)).font(Design.Typeface.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let text):
            Text(text).font(Design.Typeface.mono)
                .padding(Design.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Design.Palette.fill, in: RoundedRectangle(cornerRadius: Design.Radius.control))
        case .rule:
            Hairline()
        }
    }

    private func listRow(_ marker: String, _ text: String, _ depth: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Text(marker).font(Design.Typeface.body).foregroundStyle(.secondary).frame(minWidth: Design.Space.m, alignment: .trailing)
            Text(MarkdownBlocks.inline(text)).font(Design.Typeface.body).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(min(depth, 4)) * Design.Space.l)
    }
}
