import SwiftUI
import AppKit
import MapKit
import FacetCore
import FacetDesign

/// `map` / `azureMap`, and the fallback for `filledMap` / `shapeMap` without a shape file:
/// MapKit base map with bubble, heat-map and path layers, legend, selection tools and geocoding progress.
struct CmpBubbleMapView: View {
    let env: CmpEnv
    /// Shown as a discreet pill (used by the choropleth fallback and for shape-file errors).
    var hint: String?

    @ObservedObject private var geocoder = CmpGeocoder.shared
    @State private var mode = CmpMapSelectMode.pan
    @State private var fitToken = 0
    @State private var focusedIndex: Int?
    @FocusState private var focused: Bool
    @State private var showRing = false

    var body: some View {
        let theme = env.theme, f = env.f
        let model = CmpMapModel(env: env, resolve: { geocoder.coordinate(for: $0) }, isMiss: { geocoder.isKnownMiss($0) })
        if !model.hasFields {
            CmpPlaceholder(systemImage: "map", title: env.spec.type.displayName,
                           message: "Add a location, or latitude and longitude, to place data on the map.", theme: theme)
        } else {
            GeometryReader { geo in
                let compact = geo.size.height < 110 || geo.size.width < 200
                let showLegend = f.bool("legend", "show", true) && !compact && (!model.legend.isEmpty || model.valueRange != nil)
                let legendTop = f.string("legend", "position", "top") != "bottom"
                VStack(spacing: 6) {
                    if showLegend, legendTop { legend(model) }
                    ZStack {
                        CmpMapKitView(config: config(model), onSelect: { indices, additive in select(indices, additive, model) })
                            .accessibilityLabel("\(env.spec.type.displayName) with \(model.points.count) points")
                        overlays(model, compact: compact)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(focused && showRing ? theme.accentColor.opacity(0.8) : theme.gridlineColor, lineWidth: focused && showRing ? 1.5 : (theme.isHighContrast ? 1 : 0.5)))
                    if showLegend, !legendTop { legend(model) }
                }
            }
            .focusable(env.isInteractive)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.rightArrow) { step(1, model); return .handled }
            .onKeyPress(.leftArrow) { step(-1, model); return .handled }
            .onKeyPress(.downArrow) { step(1, model); return .handled }
            .onKeyPress(.upArrow) { step(-1, model); return .handled }
            .onKeyPress(.space) { activateFocused(model); return .handled }
            .onKeyPress(.return) { activateFocused(model); return .handled }
            .onKeyPress(.escape) { focusedIndex = nil; mode = .pan; env.context.onSelect([], false); return .handled }
            .onChange(of: focused) { _, isFocused in
                showRing = isFocused && CmpMapChromeFocus.arrivedByKeyboard
                if !isFocused { focusedIndex = nil }
            }
            .onAppear { geocoder.resolve(model.pending) }
            .onChange(of: model.pending) { _, pending in geocoder.resolve(pending) }
        }
    }

    // MARK: Configuration

    private func config(_ model: CmpMapModel) -> CmpMapKitConfig {
        let theme = env.theme, f = env.f
        var c = CmpMapKitConfig()
        c.points = model.points
        c.signature = model.signature
        let isFallback = env.spec.type == .filledMap || env.spec.type == .shapeMap
        c.showBubbles = isFallback || f.bool("layers", "bubble", true)
        c.showHeat = !isFallback && f.bool("layers", "heatmap", false)
        c.showPath = !isFallback && f.bool("layers", "path", false)
        c.style = f.string("map", "style", "standard")
        c.isDark = theme.isDark
        c.isHighContrast = theme.isHighContrast
        c.autoZoom = f.bool("map", "autoZoom", true)
        c.showControls = f.bool("map", "showControls", true)
        c.interactive = env.isInteractive
        c.mode = mode
        c.fitToken = fitToken
        c.bubbleOpacity = 1 - max(0, min(100, f.double("bubbles", "transparency", 25))) / 100
        c.bubbleOutline = f.bool("bubbles", "outline", true)
        c.outlineHex = theme.cardBackground
        c.accentHex = theme.accent
        c.heatRadius = CGFloat(max(4, f.double("heatmap", "radius", 28)))
        c.heatIntensity = max(0.05, f.double("heatmap", "intensity", 1))
        c.heatOpacity = 1 - max(0, min(100, f.double("heatmap", "transparency", 30))) / 100
        c.heatRamp = [theme.center, theme.good, theme.neutral, theme.bad]
        c.pathWidth = CGFloat(max(0.5, f.double("path", "width", 2)))
        c.pathHex = f.value("path", "color")?.stringValue
        c.emphasis = model.points.map { $0.selection.map(env.context.emphasis) ?? (env.context.selection.isEmpty ? 1 : 0.3) }
        c.selected = model.points.map { p in !env.context.selection.isEmpty && (p.selection.map(env.context.isSelected) ?? false) }
        c.focusedIndex = focusedIndex
        c.showTooltips = f.bool("tooltips", "show", true)
        return c
    }

    // MARK: Overlays

    @ViewBuilder private func overlays(_ model: CmpMapModel, compact: Bool) -> some View {
        let theme = env.theme
        if env.isInteractive, !compact, env.f.bool("map", "selectionTools", true) {
            CmpMapToolbar(theme: theme) {
                CmpMapToolButton(systemImage: "hand.draw", help: "Pan and click to select", isOn: mode == .pan, theme: theme) { mode = .pan }
                CmpMapToolButton(systemImage: "rectangle.dashed", help: "Rectangle select (⌘ adds to the selection)", isOn: mode == .rectangle, theme: theme) { mode = .rectangle }
                CmpMapToolButton(systemImage: "lasso", help: "Lasso select (⌘ adds to the selection)", isOn: mode == .lasso, theme: theme) { mode = .lasso }
                CmpMapToolButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Zoom to fit", theme: theme) { fitToken += 1 }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            if let i = focusedIndex, let p = model.points[safe: i] {
                CmpMapTooltip(content: p.tooltip, theme: theme)
            }
            if geocoder.isWorking, model.usesGeocoding, !compact {
                CmpMapPill(text: "Locating \(min(geocoder.done + 1, geocoder.total)) of \(geocoder.total)…", theme: theme) {
                    ProgressView(value: Double(geocoder.done), total: Double(max(1, geocoder.total)))
                        .progressViewStyle(.linear).frame(width: 44).tint(theme.accentColor)
                }
                .accessibilityLabel("Locating places, \(geocoder.done) of \(geocoder.total) done")
            } else if let error = geocoder.lastError, model.usesGeocoding, !model.pending.isEmpty, !compact {
                CmpMapPill(text: error, theme: theme) { Image(systemName: "wifi.exclamationmark").font(.system(size: 10)).foregroundStyle(theme.secondaryColor) }
            } else if !model.notFound.isEmpty, !compact {
                CmpMapPill(text: "\(model.notFound.count) location\(model.notFound.count == 1 ? "" : "s") not found", theme: theme) {
                    Image(systemName: "questionmark.circle").font(.system(size: 10)).foregroundStyle(theme.secondaryColor)
                }
                .help("Not found: " + model.notFound.prefix(20).joined(separator: ", "))
            }
            if let hint, !compact {
                CmpMapPill(text: hint, theme: theme) { Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(theme.secondaryColor) }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func legend(_ model: CmpMapModel) -> some View {
        if let range = model.valueRange, let vc = model.valueColumn {
            let fmt = env.data.formats[safe: vc] ?? ""
            let mid = env.f.value("fill", "midColor")?.stringValue
            let stops = [env.f.string("fill", "minColor", env.theme.minimum)] + (mid.map { [$0] } ?? []) + [env.f.string("fill", "maxColor", env.theme.maximum)]
            CmpMapGradientLegend(title: env.caption(vc), minLabel: CmpNumber.callout(.double(range.min), format: fmt),
                                 maxLabel: CmpNumber.callout(.double(range.max), format: fmt),
                                 stops: stops.map { Color(hex: $0) }, theme: env.theme)
        } else {
            CmpMapCategoryLegend(title: model.legendTitle, entries: model.legend.map { ($0.label, Color(hex: $0.colorHex)) }, theme: env.theme)
        }
    }

    // MARK: Selection and keyboard

    private func select(_ indices: [Int], _ additive: Bool, _ model: CmpMapModel) {
        var seen = Set<String>()
        let points = indices.compactMap { model.points[safe: $0]?.selection }.filter { seen.insert($0.key).inserted }
        env.context.onSelect(points, additive)
    }

    private func step(_ delta: Int, _ model: CmpMapModel) {
        guard !model.points.isEmpty else { return }
        let n = model.points.count
        showRing = true
        focusedIndex = focusedIndex.map { ($0 + delta + n) % n } ?? (delta > 0 ? 0 : n - 1)
    }

    private func activateFocused(_ model: CmpMapModel) {
        guard let i = focusedIndex else { return }
        select([i], NSEvent.modifierFlags.contains(.command), model)
    }
}
