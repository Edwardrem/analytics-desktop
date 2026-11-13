import SwiftUI
import FacetCore
import FacetDesign

/// Hierarchy slicer: an expandable tree with tri-state checks. Writes `SlicerState.hierarchyPaths`
/// (a short path selects the whole subtree; the set is kept normalised).
struct CmpSlTreeView: View {
    let session: CmpSlSession
    let roots: [CmpSlNode]
    let appearance: CmpSlRow.Appearance
    var forceSearch = false
    @State private var expandedOverride: Set<String>?
    @State private var query = ""
    @State private var active = 0
    @State private var keyFocused = false

    private struct Line: Identifiable {
        let node: CmpSlNode
        let depth: Int
        var id: String { node.key }
    }

    var body: some View {
        let cfg = session.cfg, env = session.env
        let paths = session.state.hierarchyPaths
        let expanded = expandedOverride ?? defaultExpanded(paths)
        let keep = CmpSlLogic.matchingKeys(roots, query: query)
        let lines = flatten(expanded: expanded, keep: keep)
        let showAll = cfg.selectAll && !cfg.singleSelect && keep == nil && !roots.isEmpty
        let offset = showAll ? 1 : 0
        VStack(alignment: .leading, spacing: 5) {
            if cfg.search || forceSearch {
                CmpSlSearchField(text: $query, env: env, cfg: cfg)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if showAll {
                            CmpSlRow(label: "Select all", check: allState(paths), appearance: appearance, env: env, cfg: cfg,
                                     expanded: false, hasChildren: false, isKeyFocused: keyFocused && active == 0) { _ in toggleAll() }
                                .id("\u{1}all")
                        }
                        ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                            CmpSlRow(label: line.node.label, check: CmpSlLogic.check(line.node.path, in: paths),
                                     appearance: appearance, env: env, cfg: cfg, radio: cfg.singleSelect,
                                     indent: CGFloat(line.depth) * 16,
                                     expanded: keep != nil || expanded.contains(line.node.key),
                                     hasChildren: !line.node.children.isEmpty,
                                     isKeyFocused: keyFocused && active == i + offset,
                                     action: { _ in active = i + offset; toggle(line.node) },
                                     onDisclosure: { setExpanded(line.node, !expanded.contains(line.node.key), expanded) })
                                .id(line.id)
                        }
                        if lines.isEmpty {
                            Text(roots.isEmpty ? "No values" : "No matches")
                                .font(env.font(cfg.fontSize)).foregroundStyle(env.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                        }
                    }
                }
                .onChange(of: active) { _, new in
                    if let line = lines[safe: new - offset] { withAnimation(Design.Motion.quick) { proxy.scrollTo(line.id) } }
                }
            }
            .modifier(CmpSlKeyNav(count: lines.count + offset, enabled: env.isInteractive, active: $active, focused: $keyFocused,
                                  activate: { i, _ in
                                      if showAll, i == 0 { toggleAll() } else if let l = lines[safe: i - offset] { toggle(l.node) }
                                  },
                                  selectAll: cfg.singleSelect ? nil : { session.update { $0.hierarchyPaths = roots.map(\.path) } },
                                  horizontal: { cur, right in
                                      guard let l = lines[safe: cur - offset] else { return false }
                                      let isOpen = expanded.contains(l.node.key)
                                      if right {
                                          if !l.node.children.isEmpty, !isOpen { setExpanded(l.node, true, expanded) }
                                          else if !l.node.children.isEmpty { active = min(lines.count + offset - 1, cur + 1) }
                                      } else if isOpen, !l.node.children.isEmpty {
                                          setExpanded(l.node, false, expanded)
                                      } else if l.depth > 0, let p = lines[..<(cur - offset)].lastIndex(where: { $0.depth == l.depth - 1 }) {
                                          active = p + offset
                                      }
                                      return true
                                  }))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Hierarchy values")
        }
    }

    /// Initially open the branches that contain a partial selection; with no selection open a short top level.
    private func defaultExpanded(_ paths: [[Value]]) -> Set<String> {
        var out = Set<String>()
        func visit(_ n: CmpSlNode) {
            if CmpSlLogic.check(n.path, in: paths) == .mixed {
                out.insert(n.key)
                n.children.forEach(visit)
            }
        }
        roots.forEach(visit)
        if out.isEmpty, roots.count <= 3 { roots.forEach { out.insert($0.key) } }
        return out
    }

    private func flatten(expanded: Set<String>, keep: Set<String>?) -> [Line] {
        var out: [Line] = []
        func visit(_ n: CmpSlNode, _ depth: Int) {
            if let keep, !keep.contains(n.key) { return }
            out.append(Line(node: n, depth: depth))
            if keep != nil || expanded.contains(n.key) { n.children.forEach { visit($0, depth + 1) } }
        }
        roots.forEach { visit($0, 0) }
        return out
    }

    private func setExpanded(_ n: CmpSlNode, _ open: Bool, _ current: Set<String>) {
        var e = current
        if open { e.insert(n.key) } else { e.remove(n.key) }
        withAnimation(Design.Motion.quick) { expandedOverride = e }
    }

    private func toggle(_ n: CmpSlNode) {
        session.update {
            $0.hierarchyPaths = CmpSlLogic.toggleNode(n, paths: $0.hierarchyPaths, roots: roots, single: session.cfg.singleSelect)
        }
    }
    private func allState(_ paths: [[Value]]) -> CmpSlCheck {
        if paths.isEmpty { return .off }
        return roots.allSatisfy { CmpSlLogic.check($0.path, in: paths) == .on } ? .on : .mixed
    }
    private func toggleAll() {
        session.update { $0.hierarchyPaths = allState($0.hierarchyPaths) == .on ? [] : roots.map(\.path) }
    }

    /// Labels of the selected paths, for the dropdown summary.
    static func summaryLabels(_ roots: [CmpSlNode], paths: [[Value]]) -> [String] {
        paths.map { p in
            var level = roots, label = p.last?.asString ?? ""
            for v in p {
                guard let n = level.first(where: { $0.value == v }) else { break }
                label = n.label; level = n.children
            }
            return label
        }
    }
}
