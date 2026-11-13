import SwiftUI
import FacetCore
import FacetDesign
import FacetVisuals

/// Transient feedback at the bottom of the window. Errors stay until dismissed.
struct StatusToast: View {
    @EnvironmentObject var store: DocumentStore
    var body: some View {
        Group {
            if let s = store.status {
                HStack(alignment: .top, spacing: Design.Space.s) {
                    Image(systemName: symbol(s.kind)).foregroundStyle(color(s.kind))
                    Text(s.text).font(Design.Typeface.body).textSelection(.enabled).lineLimit(8).fixedSize(horizontal: false, vertical: true)
                    Button { store.status = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 3)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, Design.Space.l).padding(.vertical, Design.Space.m)
                .frame(maxWidth: 560)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).strokeBorder(Design.Palette.hairline))
                .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
                .padding(.bottom, 52)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: s.id) {
                    guard s.kind != .error else { return }
                    try? await Task.sleep(nanoseconds: UInt64(max(3.5, Double(s.text.count) / 18) * 1_000_000_000))
                    if store.status?.id == s.id { store.status = nil }
                }
            }
        }
        .animation(Design.Motion.standard, value: store.status)
    }
    private func symbol(_ k: StatusMessage.Kind) -> String {
        switch k { case .info: return "info.circle"; case .success: return "checkmark.circle.fill"; case .warning: return "exclamationmark.triangle.fill"; case .error: return "xmark.octagon.fill" }
    }
    private func color(_ k: StatusMessage.Kind) -> Color {
        switch k { case .info: return .secondary; case .success: return Design.Palette.positive; case .warning: return Design.Palette.caution; case .error: return Design.Palette.negative }
    }
}

/// A single visual, enlarged, over a dimmed window.
struct FocusOverlay: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea().onTapGesture { store.focusVisualID = nil }
            VStack(alignment: .trailing, spacing: Design.Space.s) {
                Button { store.focusVisualID = nil } label: { Label("Back to report", systemImage: "chevron.left") }
                    .keyboardShortcut(.escape, modifiers: [])
                VisualView(spec: spec, data: store.visualData[spec.id] ?? VisualData(), context: store.context(for: spec))
                    .shadow(color: .black.opacity(0.15), radius: 30, y: 10)
            }
            .padding(48)
        }
    }
}

/// The data behind a visual, as an accessible table.
struct ShowAsTableOverlay: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    var body: some View {
        let data = store.visualData[spec.id] ?? VisualData()
        var table = VisualSpec(type: .table, frame: Frame(x: 0, y: 0, width: 800, height: 500), name: spec.name)
        let _ = { table.setFmt("title", "text", .string(spec.name)) }()
        var tableData = data
        let _ = { tableData.roles = [Well.values.rawValue: Array(0..<data.table.columnCount)] }()
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea().onTapGesture { store.showAsTableID = nil }
            VStack(alignment: .trailing, spacing: Design.Space.s) {
                Button { store.showAsTableID = nil } label: { Label("Back to report", systemImage: "chevron.left") }
                    .keyboardShortcut(.escape, modifiers: [])
                VisualView(spec: table, data: tableData, context: store.context(for: table, interactive: false))
                    .shadow(color: .black.opacity(0.15), radius: 30, y: 10)
            }
            .padding(48)
        }
    }
}

/// Reading view: the page as readers see it, with page and bookmark navigation.
struct PresentationView: View {
    @EnvironmentObject var store: DocumentStore
    var body: some View {
        GeometryReader { geo in
            let page = store.currentPage
            let scale = max(0.1, min(geo.size.width / page.size.width, (geo.size.height - 44) / page.size.height))
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    store.theme.backgroundColor
                    if let c = page.background.color { Color(hex: c).opacity(1 - page.background.transparency / 100) }
                    ForEach(page.visuals.filter { !$0.isHidden }.sorted { $0.zIndex < $1.zIndex }) { spec in
                        VisualView(spec: spec, data: store.visualData[spec.id] ?? VisualData(), context: store.context(for: spec))
                            .frame(width: spec.frame.width, height: spec.frame.height)
                            .offset(x: spec.frame.x, y: spec.frame.y)
                    }
                }
                .frame(width: page.size.width, height: page.size.height, alignment: .topLeading)
                .scaleEffect(scale)
                .frame(width: page.size.width * scale, height: page.size.height * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.92))
                HStack(spacing: Design.Space.m) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [])
                    Text(page.name).font(Design.Typeface.bodyStrong)
                    Button { step(1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: [])
                    if !store.report.bookmarks.isEmpty {
                        Menu("Bookmarks") {
                            ForEach(store.report.bookmarks) { b in Button(b.name) { store.applyBookmark(b.id) } }
                        }.fixedSize()
                    }
                    Spacer()
                    Button("Done") { store.presenting = false }.keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, Design.Space.l).frame(height: 44)
                .background(.bar)
            }
        }
    }
    private func step(_ d: Int) {
        let pages = store.report.pages.filter { !$0.isHidden }
        guard let i = pages.firstIndex(where: { $0.id == store.currentPageID }), let next = pages[safe: i + d] else { return }
        store.goToPage(next.id)
    }
}
