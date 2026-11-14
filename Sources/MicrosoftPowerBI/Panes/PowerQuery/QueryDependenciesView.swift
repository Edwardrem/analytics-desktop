import SwiftUI
import FacetCore
import FacetDesign
import FacetQuery

/// The Query Dependencies diagram as data: data sources on the left, then queries in dependency order,
/// with an edge from each source or query to the queries that use it.
struct DependencyLayout: Equatable {
    enum Kind: Equatable { case source, query, parameter, function }
    struct Node: Identifiable, Equatable {
        var id: String
        var title: String
        var subtitle: String
        var kind: Kind
        var column: Int
        var row: Int
    }
    struct Edge: Equatable, Hashable { var from: String; var to: String }

    var nodes: [Node] = []
    var edges: [Edge] = []

    static func queryID(_ name: String) -> String { "query:" + name }
    static func sourceID(_ s: QueryDataSource) -> String { "source:\(s.kind)|\(s.location)" }

    static func make(queries: [QueryDefinition]) -> DependencyLayout {
        var layout = DependencyLayout()
        let graph = QueryDependencyGraph(queries: queries)
        let byName = Dictionary(queries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        // Sources, in order of first use.
        var sources: [QueryDataSource] = []
        for q in queries where q.kind != .parameter {
            for s in MScript.sourceReferences(in: q.mScript) {
                if !sources.contains(s) { sources.append(s) }
                layout.edges.append(Edge(from: sourceID(s), to: queryID(q.name)))
            }
        }
        for (row, s) in sources.enumerated() {
            let title = s.location.contains("://") ? s.location : (s.location as NSString).lastPathComponent
            layout.nodes.append(Node(id: sourceID(s), title: title.isEmpty ? s.location : title, subtitle: s.kind, kind: .source, column: 0, row: row))
        }
        let firstColumn = sources.isEmpty ? 0 : 1
        for (level, names) in graph.levels().enumerated() {
            for (row, name) in names.enumerated() {
                guard let q = byName[name] else { continue }
                let kind: Kind = q.kind == .parameter ? .parameter : q.kind == .function ? .function : .query
                let subtitle: String
                switch kind {
                case .parameter: subtitle = "Parameter"
                case .function: subtitle = "Function"
                default: subtitle = q.loadEnabled ? "Loaded to the model" : "Connection only"
                }
                layout.nodes.append(Node(id: queryID(name), title: name, subtitle: subtitle, kind: kind, column: firstColumn + level, row: row))
            }
        }
        for q in queries {
            for d in graph.dependencies[q.name] ?? [] { layout.edges.append(Edge(from: queryID(d), to: queryID(q.name))) }
        }
        return layout
    }

    /// Nodes connected to `id` (upstream and downstream), including itself.
    func connected(to id: String) -> Set<String> {
        var seen: Set<String> = [id]
        var up = [id], down = [id]
        while let n = up.popLast() { for e in edges where e.to == n && seen.insert(e.from).inserted { up.append(e.from) } }
        while let n = down.popLast() { for e in edges where e.from == n && seen.insert(e.to).inserted { down.append(e.to) } }
        return seen
    }
}

/// View ▸ Query Dependencies.
struct QueryDependenciesView: View {
    @ObservedObject var session: QueryEditorSession
    @State private var focus: String?
    @State private var zoom: CGFloat = 1
    @Environment(\.dismiss) private var dismiss

    private static let nodeSize = CGSize(width: 190, height: 52)
    private static let spacing = CGSize(width: 250, height: 74)

    var body: some View {
        let layout = DependencyLayout.make(queries: session.queries)
        let lit = focus.map(layout.connected) ?? []
        VStack(spacing: 0) {
            HStack {
                Text("Query Dependencies").font(Design.Typeface.headline)
                Spacer()
                IconButton("minus.magnifyingglass", help: "Zoom out") { zoom = max(0.5, zoom - 0.1) }
                IconButton("plus.magnifyingglass", help: "Zoom in") { zoom = min(1.6, zoom + 0.1) }
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(Design.Space.m)
            Hairline()
            if layout.nodes.isEmpty {
                EmptyState(systemImage: "point.3.connected.trianglepath.dotted", title: "No queries")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    diagram(layout, lit: lit).scaleEffect(zoom, anchor: .topLeading)
                        .frame(width: size(layout).width * zoom, height: size(layout).height * zoom, alignment: .topLeading)
                }
                .background(Design.Palette.canvas)
            }
            Hairline()
            Text("Select a node to highlight what it depends on and what depends on it.").font(Design.Typeface.caption).foregroundStyle(.secondary).padding(Design.Space.s)
        }
        .frame(width: 900, height: 600)
    }

    private func size(_ layout: DependencyLayout) -> CGSize {
        let columns = (layout.nodes.map(\.column).max() ?? 0) + 1, rows = (layout.nodes.map(\.row).max() ?? 0) + 1
        return CGSize(width: CGFloat(columns) * Self.spacing.width + 40, height: CGFloat(rows) * Self.spacing.height + 40)
    }
    private func origin(_ n: DependencyLayout.Node) -> CGPoint {
        CGPoint(x: 20 + CGFloat(n.column) * Self.spacing.width, y: 20 + CGFloat(n.row) * Self.spacing.height)
    }

    private func diagram(_ layout: DependencyLayout, lit: Set<String>) -> some View {
        let byID = Dictionary(layout.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for e in layout.edges {
                    guard let a = byID[e.from], let b = byID[e.to] else { continue }
                    let start = CGPoint(x: origin(a).x + Self.nodeSize.width, y: origin(a).y + Self.nodeSize.height / 2)
                    let end = CGPoint(x: origin(b).x, y: origin(b).y + Self.nodeSize.height / 2)
                    var path = Path()
                    path.move(to: start)
                    let dx = max(40, (end.x - start.x) / 2)
                    path.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
                    let on = lit.isEmpty || (lit.contains(e.from) && lit.contains(e.to))
                    context.stroke(path, with: .color(on ? Color.accentColor.opacity(lit.isEmpty ? 0.5 : 0.9) : Color.secondary.opacity(0.15)), lineWidth: on && !lit.isEmpty ? 2 : 1)
                    var arrow = Path()
                    arrow.move(to: end)
                    arrow.addLine(to: CGPoint(x: end.x - 7, y: end.y - 4))
                    arrow.addLine(to: CGPoint(x: end.x - 7, y: end.y + 4))
                    arrow.closeSubpath()
                    context.fill(arrow, with: .color(on ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.2)))
                }
            }
            .frame(width: size(layout).width, height: size(layout).height)
            ForEach(layout.nodes) { n in
                node(n, dimmed: !lit.isEmpty && !lit.contains(n.id), selected: focus == n.id)
                    .offset(x: origin(n).x, y: origin(n).y)
                    .onTapGesture { focus = focus == n.id ? nil : n.id }
            }
        }
        .frame(width: size(layout).width, height: size(layout).height, alignment: .topLeading)
    }

    private func node(_ n: DependencyLayout.Node, dimmed: Bool, selected: Bool) -> some View {
        let symbol: String
        switch n.kind {
        case .source: symbol = n.subtitle == "SQLite" ? "cylinder" : n.subtitle == "Web" || n.subtitle == "OData" ? "globe" : n.subtitle == "Folder" ? "folder" : "doc"
        case .query: symbol = "tablecells"
        case .parameter: symbol = "slider.horizontal.3"
        case .function: symbol = "function"
        }
        return HStack(spacing: Design.Space.s) {
            Image(systemName: symbol).foregroundStyle(n.kind == .source ? Color.secondary : Color.accentColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(n.title).font(Design.Typeface.bodyStrong).lineLimit(1).truncationMode(.middle)
                Text(n.subtitle).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.s)
        .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
        .facetCard(radius: Design.Radius.control)
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
        .opacity(dimmed ? 0.35 : 1)
        .help(n.kind == .source ? "\(n.subtitle): \(n.title)" : n.title)
    }
}
