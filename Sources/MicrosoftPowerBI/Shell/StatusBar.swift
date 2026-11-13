import SwiftUI
import FacetCore
import FacetDesign

/// The words and numbers of the status bar, kept apart from its view.
enum StatusModel {
    static let zoomRange: ClosedRange<Double> = 0.1...4

    /// "Page 2 of 5". `index` is zero-based; nil when the current page is not in the report.
    static func pageLabel(index: Int?, count: Int) -> String {
        guard count > 0 else { return "No pages" }
        guard let index, index >= 0, index < count else { return "\(count) page\(count == 1 ? "" : "s")" }
        return "Page \(index + 1) of \(count)"
    }

    static func name(of mode: StorageMode) -> String {
        switch mode {
        case .import: return "Import"
        case .directQuery: return "DirectQuery"
        case .dual: return "Dual"
        case .directLake: return "Direct Lake"
        case .live: return "Live connection"
        }
    }

    /// How the model's tables are stored: one mode's name, "Mixed", or nil when there are no tables.
    static func storageLabel(_ modes: [StorageMode]) -> String? {
        let unique = Set(modes)
        guard let first = unique.first else { return nil }
        if unique.count > 1 { return "Mixed" }
        return name(of: first)
    }

    /// Where a zoom factor sits on the slider, 0…1. The scale is logarithmic so 100% is near the middle.
    static func sliderPosition(zoom: Double) -> Double {
        let z = min(max(zoom.isFinite ? zoom : 1, zoomRange.lowerBound), zoomRange.upperBound)
        return log(z / zoomRange.lowerBound) / log(zoomRange.upperBound / zoomRange.lowerBound)
    }
    /// The zoom factor for a slider position, to the whole percent, snapping to 100% when close.
    static func zoom(sliderPosition: Double) -> Double {
        let p = min(max(sliderPosition.isFinite ? sliderPosition : 0, 0), 1)
        let z = zoomRange.lowerBound * pow(zoomRange.upperBound / zoomRange.lowerBound, p)
        if abs(z - 1) < 0.04 { return 1 }
        return min(max((z * 100).rounded() / 100, zoomRange.lowerBound), zoomRange.upperBound)
    }
    static func percent(_ zoom: Double) -> String { "\(Int(((zoom.isFinite ? zoom : 1) * 100).rounded()))%" }
}

/// "Fit to page": the largest zoom at which the whole page shows in the canvas.
enum CanvasFit {
    /// Space kept clear around the page, each side.
    static let margin: Double = 16
    static func scale(viewport: CGSize, page: CGSize) -> Double {
        guard page.width > 0, page.height > 0 else { return 1 }
        let w = (Double(viewport.width) - margin * 2) / Double(page.width)
        let h = (Double(viewport.height) - margin * 2) / Double(page.height)
        let s = min(w, h)
        return s.isFinite ? min(max(s, StatusModel.zoomRange.lowerBound), StatusModel.zoomRange.upperBound) : 1
    }
}

/// The bar along the bottom of the window: where you are, what the document is doing, how the
/// model is stored, and the zoom.
struct StatusBar: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        HStack(spacing: Design.Space.m) {
            if store.view == .report {
                Text(StatusModel.pageLabel(index: store.report.pages.firstIndex { $0.id == store.currentPageID },
                                           count: store.report.pages.count))
                    .monospacedDigit()
                if store.selection.count > 1 { Text("\(store.selection.count) visuals selected") }
            } else {
                Text("\(store.view.title) view")
            }
            activity
            Spacer(minLength: Design.Space.s)
            if store.mobileLayout && store.view == .report {
                Label("Mobile layout", systemImage: "iphone").foregroundStyle(Color.accentColor)
            }
            connection
            if store.view == .report { zoom }
        }
        .font(Design.Typeface.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, Design.Space.m)
        .frame(height: ShellMetrics.statusBarHeight)
        .background(Design.Palette.surface)
    }

    /// What the document is doing right now, most important first.
    @ViewBuilder private var activity: some View {
        if let p = store.refreshProgress {
            HStack(spacing: Design.Space.xs) {
                ProgressView().controlSize(.mini)
                Text(p.query.isEmpty ? "Refreshing data…" : "Refreshing \(p.query)…")
            }
        } else if !store.loadingVisuals.isEmpty {
            HStack(spacing: Design.Space.xs) {
                ProgressView().controlSize(.mini)
                Text("Updating \(store.loadingVisuals.count) visual\(store.loadingVisuals.count == 1 ? "" : "s")…")
            }
        }
        if store.visualsPaused {
            Label(store.pendingWhilePaused.isEmpty ? "Visuals paused" : "Visuals paused · \(store.pendingWhilePaused.count) pending",
                  systemImage: "pause.circle")
                .help("Queries are paused while you build. Use Optimize ▸ Refresh visuals or resume.")
        }
        if !store.viewAsRoles.isEmpty {
            Label("Viewing as \(store.viewAsRoles.joined(separator: ", "))", systemImage: "person.crop.rectangle")
        }
        if !store.modelErrors.isEmpty {
            Label("\(store.modelErrors.count) model error\(store.modelErrors.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Design.Palette.caution)
                .help(store.modelErrors.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
        }
    }

    /// Storage mode of the model, as Windows shows at the bottom right.
    @ViewBuilder private var connection: some View {
        if let mode = StatusModel.storageLabel(store.model.tables.map(\.storageMode)) {
            let tables = store.model.tables.count
            Text("Storage mode: \(mode)")
                .help("\(tables) table\(tables == 1 ? "" : "s") in the model · \(store.doc.queries.count) quer\(store.doc.queries.count == 1 ? "y" : "ies")")
        } else {
            Text("No data loaded").help("Use Home ▸ Get data to connect to a source")
        }
    }

    private var zoom: some View {
        HStack(spacing: Design.Space.xxs) {
            IconButton("minus", help: "Zoom out (⌘−)") { AppCommands.run("view.zoomOut", store) }
            Slider(value: Binding(
                get: { StatusModel.sliderPosition(zoom: store.zoom) },
                set: { store.fitToWindow = false; store.zoom = StatusModel.zoom(sliderPosition: $0) }))
                .controlSize(.mini)
                .frame(width: 110)
                .help("Zoom")
                .accessibilityLabel("Zoom")
            IconButton("plus", help: "Zoom in (⌘+)") { AppCommands.run("view.zoomIn", store) }
            Button { AppCommands.run("view.actualSize", store) } label: {
                Text(StatusModel.percent(store.zoom)).monospacedDigit().frame(width: Design.Space.xxl + Design.Space.s, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom level — click for actual size (100%)")
            IconButton("arrow.up.left.and.arrow.down.right", help: "Fit to page (⌘0)", isOn: store.fitToWindow) {
                AppCommands.run("view.fit", store)
            }
        }
    }
}
