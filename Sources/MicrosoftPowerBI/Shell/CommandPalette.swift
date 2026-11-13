import SwiftUI
import FacetCore
import FacetDesign

/// ⌘K: every command, searchable.
struct CommandPalette: View {
    @EnvironmentObject var store: DocumentStore
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var results: [AppCommand] {
        let all = AppCommands.all.filter { $0.isEnabled(store) }
        guard !query.isEmpty else { return Array(all.prefix(60)) }
        let q = query.lowercased()
        return all.compactMap { c -> (AppCommand, Int)? in
            let t = c.title.lowercased()
            if t.hasPrefix(q) { return (c, 0) }
            if t.contains(q) { return (c, 1) }
            if c.menu.rawValue.lowercased().contains(q) { return (c, 3) }
            // Subsequence match: "nm" finds "New Measure".
            var it = t.makeIterator()
            for ch in q { var found = false; while let n = it.next() { if n == ch { found = true; break } }; if !found { return nil } }
            return (c, 2)
        }.sorted { $0.1 < $1.1 }.prefix(60).map(\.0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { isPresented = false }
            VStack(spacing: 0) {
                HStack(spacing: Design.Space.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search commands", text: $query).textFieldStyle(.plain).font(.system(size: 17)).focused($focused)
                        .onSubmit { runSelected() }
                }
                .padding(Design.Space.l)
                Hairline()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, c in
                                HStack(spacing: Design.Space.m) {
                                    Image(systemName: c.symbol.isEmpty ? "circle.fill" : c.symbol).font(.system(size: c.symbol.isEmpty ? 4 : 12))
                                        .foregroundStyle(.secondary).frame(width: 20)
                                    Text(c.title).font(Design.Typeface.body)
                                    Spacer()
                                    Text(c.menu.rawValue).font(Design.Typeface.caption).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, Design.Space.l).padding(.vertical, 7)
                                .background(i == index ? Color.accentColor.opacity(0.14) : .clear)
                                .contentShape(Rectangle())
                                .onTapGesture { index = i; runSelected() }
                                .id(i)
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: index) { _, i in proxy.scrollTo(i) }
                }
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous).strokeBorder(Design.Palette.hairlineStrong))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 16)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(0, results.count - 1)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
    }
    private func runSelected() {
        guard let c = results[safe: index] else { return }
        isPresented = false
        c.run(store)
    }
}
