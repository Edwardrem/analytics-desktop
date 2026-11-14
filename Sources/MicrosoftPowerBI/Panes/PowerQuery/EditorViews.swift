import SwiftUI
import AppKit
import FacetCore
import FacetDesign
import FacetQuery

// The views of the new Power Query editor (Settings ▸ Preview features): schema view and query script view in place
// of the data preview, and the diagram view above it. All of them edit the same pending queries as the data view.

// MARK: - Schema view

/// The selected step's columns as a list: select columns and transform them (header menus, ribbon) without the data.
struct SchemaView: View {
    @ObservedObject var session: QueryEditorSession

    var body: some View {
        if let preview = session.preview, preview.valueKind == "table" {
            let profiles = Dictionary(session.profiles.map { ($0.column, $0) }, uniquingKeysWith: { a, _ in a })
            VStack(spacing: 0) {
                HStack(spacing: Design.Space.s) {
                    Text("Column name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Data type").frame(width: 150, alignment: .leading)
                    Text("Errors").frame(width: 56, alignment: .trailing)
                    Text("Empty").frame(width: 56, alignment: .trailing)
                }
                .font(Design.Typeface.captionStrong).foregroundStyle(.secondary)
                .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
                Hairline()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(preview.table.columns.indices, id: \.self) { i in
                            if let column = preview.table.columns[safe: i] {
                                row(column, profile: profiles[column.name])
                                Hairline()
                            }
                        }
                    }
                }
                Hairline()
                Text("\(preview.table.columnCount) column\(preview.table.columnCount == 1 ? "" : "s")\(session.selectedColumns.isEmpty ? "" : ", \(session.selectedColumns.count) selected"). Right-click a column for its transformations.")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
            }
        } else {
            // Lists, records, functions, parameters and errors have no schema: show them as the data view does.
            PreviewArea(session: session)
        }
    }

    private func row(_ column: DataColumn, profile: ColumnProfile?) -> some View {
        let selected = session.selectedColumns.contains(column.name)
        return HStack(spacing: Design.Space.s) {
            Text(column.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Button {
                focus(column.name)
                EditorMenus.popUp(EditorMenus.menu(DataTypeCommands.types.map { .command(DataTypeCommands.id($0.type)) } + [.divider, .command("pq.typeLocale")], session: session))
            } label: {
                Label(DataTypeCommands.types.first { $0.type == column.type }?.title ?? "Any", systemImage: QueryCellText.typeSymbol(column.type))
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .frame(width: 150, alignment: .leading)
            .help("Change the data type of \(column.name)")
            Text(profile.map { "\($0.errorCount)" } ?? "")
                .foregroundStyle((profile?.errorCount ?? 0) > 0 ? Design.Palette.negative : .secondary)
                .frame(width: 56, alignment: .trailing)
            Text(profile.map { "\($0.emptyCount)" } ?? "").foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
        }
        .font(Design.Typeface.body)
        .monospacedDigit()
        .padding(.horizontal, Design.Space.m).padding(.vertical, 5)
        .background(selected ? Design.Palette.accent.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            session.clickColumn(column.name, toggle: flags.contains(.command), range: flags.contains(.shift))
        }
        .overlay(ContextMenuCatcher { focus(column.name); return EditorMenus.menu(EditorMenus.contextEntries, session: session) })
    }

    private func focus(_ column: String) {
        if !session.selectedColumns.contains(column) { session.selectedColumns = [column] }
    }
}

// MARK: - Query script view

/// The whole M script of the selected query, edited in place (the Advanced Editor, always open).
struct QueryScriptView: View {
    @ObservedObject var session: QueryEditorSession
    @State private var draft = ""
    @State private var problem: String?

    private var script: String { session.selectedQuery?.mScript ?? "" }

    var body: some View {
        if let q = session.selectedQuery {
            VStack(spacing: 0) {
                HStack(spacing: Design.Space.s) {
                    Image(systemName: QueriesPane.symbol(q)).foregroundStyle(.secondary)
                    Text(q.name).font(Design.Typeface.bodyStrong).lineLimit(1)
                    Spacer()
                    Button("Revert") { reset() }.disabled(draft == script)
                        .help("Go back to the query's current script")
                    Button("Apply") { problem = session.setScript(draft) }.disabled(draft == script)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Check the script and make it the query's steps (⌘Return)")
                }
                .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
                Hairline()
                TextEditor(text: $draft)
                    .font(Design.Typeface.mono)
                    .scrollContentBackground(.hidden)
                    .padding(Design.Space.s)
                if let problem {
                    Hairline()
                    Text(problem).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Design.Space.s)
                }
            }
            .onAppear { reset() }
            .onChange(of: script) { _, _ in reset() }
            .onChange(of: session.selectedQueryID) { _, _ in reset() }
        } else {
            EmptyState(systemImage: "curlybraces", title: "Select a query")
        }
    }

    private func reset() { draft = script; problem = nil }
}

// MARK: - Diagram view

/// Every query as a card with its applied steps, in dependency order, with an arrow from each query to the queries
/// that use it. Clicking a card selects the query; clicking a step selects that step.
struct QueryDiagramView: View {
    @ObservedObject var session: QueryEditorSession

    struct Card: Equatable {
        var node: DependencyLayout.Node
        var steps: [String]
    }

    static let cardWidth: CGFloat = 200
    static let header: CGFloat = 30
    static let stepHeight: CGFloat = 19
    static let maxSteps = 6
    static let gap = CGSize(width: 56, height: 22)

    /// Query cards (sources left out: each query's Source step names them) and the edges between queries.
    static func cards(_ queries: [QueryDefinition]) -> (cards: [Card], edges: [DependencyLayout.Edge]) {
        let layout = DependencyLayout.make(queries: queries)
        let byName = Dictionary(queries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let hasSources = layout.nodes.contains { $0.kind == .source }
        let cards = layout.nodes.filter { $0.kind != .source }.map { n -> Card in
            var node = n
            if hasSources { node.column -= 1 }
            let name = String(n.id.dropFirst("query:".count))
            let q = byName[name]
            let steps = q.map { $0.kind == .parameter ? [] : MScript.steps(of: $0.mScript).map(\.name) } ?? []
            return Card(node: node, steps: steps)
        }
        return (cards, layout.edges.filter { $0.from.hasPrefix("query:") })
    }

    static func height(_ card: Card) -> CGFloat {
        let shown = min(card.steps.count, maxSteps)
        return header + CGFloat(shown) * stepHeight + (card.steps.count > maxSteps ? stepHeight : 0) + 6
    }

    var body: some View {
        let (cards, edges) = Self.cards(session.queries)
        let rowHeight = (cards.map(Self.height).max() ?? Self.header) + Self.gap.height
        let columns = (cards.map(\.node.column).max() ?? 0) + 1, rows = (cards.map(\.node.row).max() ?? 0) + 1
        let size = CGSize(width: CGFloat(columns) * (Self.cardWidth + Self.gap.width) + Self.gap.width,
                          height: CGFloat(rows) * rowHeight + Self.gap.height)
        func origin(_ c: Card) -> CGPoint {
            CGPoint(x: Self.gap.width + CGFloat(c.node.column) * (Self.cardWidth + Self.gap.width), y: Self.gap.height + CGFloat(c.node.row) * rowHeight)
        }
        let byID = Dictionary(cards.map { ($0.node.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Group {
            if cards.isEmpty {
                EmptyState(systemImage: "rectangle.3.group", title: "No queries")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            for e in edges {
                                guard let a = byID[e.from], let b = byID[e.to] else { continue }
                                let start = CGPoint(x: origin(a).x + Self.cardWidth, y: origin(a).y + Self.header / 2)
                                let end = CGPoint(x: origin(b).x, y: origin(b).y + Self.header / 2)
                                var path = Path()
                                path.move(to: start)
                                let dx = max(24, (end.x - start.x) / 2)
                                path.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
                                context.stroke(path, with: .color(Color.accentColor.opacity(0.6)), lineWidth: 1)
                                var arrow = Path()
                                arrow.move(to: end)
                                arrow.addLine(to: CGPoint(x: end.x - 7, y: end.y - 4))
                                arrow.addLine(to: CGPoint(x: end.x - 7, y: end.y + 4))
                                arrow.closeSubpath()
                                context.fill(arrow, with: .color(Color.accentColor.opacity(0.8)))
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        ForEach(cards, id: \.node.id) { c in
                            card(c).offset(x: origin(c).x, y: origin(c).y)
                        }
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                }
                .background(Design.Palette.canvas)
            }
        }
    }

    private func card(_ c: Card) -> some View {
        let q = session.queries.first { DependencyLayout.queryID($0.name) == c.node.id }
        let selected = q?.id == session.selectedQueryID
        let current = selected ? session.currentStepIndex : nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.Space.xs) {
                Image(systemName: q.map(QueriesPane.symbol) ?? "tablecells").foregroundStyle(Color.accentColor).frame(width: 16)
                Text(c.node.title).font(Design.Typeface.bodyStrong).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let q, session.queryErrors[q.id] != nil {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Design.Palette.caution)
                }
            }
            .frame(height: Self.header)
            .contentShape(Rectangle())
            .onTapGesture { if let q { session.selectedQueryID = q.id } }
            ForEach(Array(c.steps.prefix(Self.maxSteps).enumerated()), id: \.offset) { i, step in
                Text(step).font(Design.Typeface.caption).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, minHeight: Self.stepHeight, alignment: .leading)
                    .padding(.horizontal, Design.Space.xs)
                    .background(current == i ? Design.Palette.accent.opacity(0.18) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { select(q, step: i) }
            }
            if c.steps.count > Self.maxSteps {
                Button("\(c.steps.count - Self.maxSteps) more step\(c.steps.count - Self.maxSteps == 1 ? "" : "s")") { select(q, step: c.steps.count - 1) }
                    .buttonStyle(.link).font(Design.Typeface.caption).frame(height: Self.stepHeight)
                    .help("Select the query's last step (Query Settings lists every step)")
            }
        }
        .padding(.horizontal, Design.Space.s).padding(.bottom, 6)
        .frame(width: Self.cardWidth, height: Self.height(c), alignment: .topLeading)
        .facetCard(radius: Design.Radius.control)
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .help(c.node.subtitle)
    }

    private func select(_ q: QueryDefinition?, step: Int) {
        guard let q else { return }
        if session.selectedQueryID != q.id { session.selectedQueryID = q.id }
        session.selectStep(step)
    }
}
