import SwiftUI
import AppKit
import MapKit
import FacetCore
import FacetDesign

/// Pointer mode of the bubble map.
enum CmpMapSelectMode: String { case pan, rectangle, lasso }

/// Everything the MapKit view draws, derived from spec + data by `CmpBubbleMapView`.
struct CmpMapKitConfig {
    var points: [CmpMapPoint] = []
    var signature = 0
    var showBubbles = true
    var showHeat = false
    var showPath = false
    var style = "standard"
    var isDark = false
    var isHighContrast = false
    var autoZoom = true
    var showControls = true
    var interactive = true
    var mode = CmpMapSelectMode.pan
    var fitToken = 0
    var bubbleOpacity = 0.75
    var bubbleOutline = true
    var outlineHex = "#FFFFFF"
    var accentHex = "#0A84FF"
    var heatRadius: CGFloat = 28
    var heatIntensity = 1.0
    var heatOpacity = 0.7
    var heatRamp: [String] = []
    var pathWidth: CGFloat = 2
    var pathHex: String?
    /// Per-point emphasis (1 selected / nothing selected, 0.3 dimmed) and selected flags.
    var emphasis: [Double] = []
    var selected: [Bool] = []
    var focusedIndex: Int?
    var showTooltips = true
}

final class CmpMapAnnotation: NSObject, MKAnnotation {
    let index: Int
    let coordinate: CLLocationCoordinate2D
    init(index: Int, coordinate: CLLocationCoordinate2D) { self.index = index; self.coordinate = coordinate }
}

/// Screen-sized bubble (does not scale with zoom), with emphasis, selection ring and tooltip.
final class CmpBubbleAnnotationView: MKAnnotationView {
    func configure(point: CmpMapPoint, config: CmpMapKitConfig, emphasis: Double, selected: Bool, focused: Bool) {
        let d = point.radius * 2
        frame = CGRect(x: 0, y: 0, width: d, height: d)
        centerOffset = .zero
        wantsLayer = true
        guard let layer else { return }
        layer.cornerRadius = point.radius
        layer.backgroundColor = CmpColor.ns(point.colorHex).withAlphaComponent(config.bubbleOpacity).cgColor
        let ringHex = selected || focused ? config.accentHex : (config.isHighContrast ? "#FFFFFF" : config.outlineHex)
        layer.borderColor = CmpColor.ns(ringHex).withAlphaComponent(selected || focused ? 1 : 0.9).cgColor
        layer.borderWidth = selected || focused ? 2 : (config.bubbleOutline ? 1 : 0)
        alphaValue = emphasis
        toolTip = config.showTooltips ? point.tooltip.plainText : nil
        canShowCallout = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(point.tooltip.title)
        setAccessibilityValue(point.tooltip.rows.map { "\($0[0]) \($0[1])" }.joined(separator: ", "))
        setAccessibilitySelected(selected)
    }
}

/// Blurred density overlay drawn above the map tiles; re-rendered whenever the visible region changes.
final class CmpHeatOverlayView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: bounds.size)
            .draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Captures a drag for rectangle / lasso selection and draws the marquee.
final class CmpLassoView: NSView {
    var mode = CmpMapSelectMode.rectangle
    var accent = NSColor.controlAccentColor
    /// Called on mouse-up with the rectangle or the lasso polygon in this view's (flipped) coordinates.
    var onFinish: ((_ rect: CGRect?, _ lasso: [CGPoint]?, _ additive: Bool) -> Void)?
    private var start: CGPoint?
    private var path: [CGPoint] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        start = p; path = [p]
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        path.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; path = []; needsDisplay = true }
        guard let start, let end = path.last else { return }
        let additive = event.modifierFlags.contains(.command)
        if mode == .rectangle {
            onFinish?(CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y).standardized, nil, additive)
        } else {
            onFinish?(nil, path, additive)
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { start = nil; path = []; needsDisplay = true } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let start, let end = path.last, path.count > 1 else { return }
        let shape: NSBezierPath
        if mode == .rectangle {
            shape = NSBezierPath(rect: CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y).standardized)
        } else {
            shape = NSBezierPath()
            shape.move(to: path[0])
            path.dropFirst().forEach { shape.line(to: $0) }
            shape.close()
        }
        accent.withAlphaComponent(0.12).setFill(); shape.fill()
        accent.setStroke(); shape.lineWidth = 1
        shape.setLineDash([4, 3], count: 2, phase: 0)
        shape.stroke()
    }
}

struct CmpMapKitView: NSViewRepresentable {
    var config: CmpMapKitConfig
    /// Indices into `config.points`; empty clears.
    var onSelect: (_ indices: [Int], _ additive: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = false
        map.register(CmpBubbleAnnotationView.self, forAnnotationViewWithReuseIdentifier: "bubble")
        let heat = CmpHeatOverlayView(frame: map.bounds)
        heat.autoresizingMask = [.width, .height]
        heat.isHidden = true
        map.addSubview(heat)
        context.coordinator.heat = heat
        let lasso = CmpLassoView(frame: map.bounds)
        lasso.autoresizingMask = [.width, .height]
        lasso.isHidden = true
        map.addSubview(lasso)
        context.coordinator.lasso = lasso
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.backgroundClick(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        click.delegate = context.coordinator
        map.addGestureRecognizer(click)
        map.setAccessibilityLabel("Map")
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(config, to: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var parent: CmpMapKitView
        weak var heat: CmpHeatOverlayView?
        weak var lasso: CmpLassoView?
        private var config = CmpMapKitConfig()
        private var signature: Int?
        private var fitToken = 0
        private var styleKey = ""
        private var layerKey = ""
        private weak var map: MKMapView?

        init(_ parent: CmpMapKitView) { self.parent = parent }

        func apply(_ new: CmpMapKitConfig, to map: MKMapView) {
            self.map = map
            let old = config
            config = new
            map.appearance = NSAppearance(named: new.isDark ? .darkAqua : .aqua)

            let styleKey = "\(new.style)|\(new.isDark)"
            if styleKey != self.styleKey {
                self.styleKey = styleKey
                switch new.style {
                case "satellite": map.preferredConfiguration = MKImageryMapConfiguration()
                case "hybrid": map.preferredConfiguration = MKHybridMapConfiguration()
                case "muted":
                    let c = MKStandardMapConfiguration(); c.emphasisStyle = .muted
                    c.pointOfInterestFilter = .excludingAll
                    map.preferredConfiguration = c
                default:
                    let c = MKStandardMapConfiguration(); c.pointOfInterestFilter = .excludingAll
                    map.preferredConfiguration = c
                }
            }
            map.showsZoomControls = new.showControls && new.interactive
            map.showsCompass = new.showControls && new.interactive
            map.isScrollEnabled = new.interactive
            map.isZoomEnabled = new.interactive
            map.isRotateEnabled = false
            map.isPitchEnabled = false

            let layerKey = "\(new.showBubbles)|\(new.showPath)|\(new.pathWidth)|\(new.pathHex ?? "")"
            let dataChanged = signature != new.signature
            if dataChanged || layerKey != self.layerKey {
                self.layerKey = layerKey
                rebuild(map)
            } else {
                refreshAnnotationViews(map)
            }
            if (dataChanged && new.autoZoom) || fitToken != new.fitToken { fit(map, animated: signature != nil && !dataChanged) }
            signature = new.signature
            fitToken = new.fitToken

            lasso?.isHidden = new.mode == .pan || !new.interactive
            lasso?.mode = new.mode
            lasso?.accent = CmpColor.ns(new.accentHex)
            lasso?.onFinish = { [weak self] rect, path, additive in self?.finishMarquee(rect: rect, lasso: path, additive: additive) }
            heat?.isHidden = !new.showHeat
            if new.showHeat || old.showHeat != new.showHeat { renderHeat() }
        }

        private func rebuild(_ map: MKMapView) {
            map.removeAnnotations(map.annotations)
            map.removeOverlays(map.overlays)
            if config.showPath {
                // One line per legend group, connecting its points in data order.
                let groups = Dictionary(grouping: config.points, by: \.group)
                for g in groups.keys.sorted() {
                    let coords = (groups[g] ?? []).map(\.coordinate)
                    guard coords.count > 1 else { continue }
                    let line = MKPolyline(coordinates: coords, count: coords.count)
                    line.title = config.pathHex ?? groups[g]?.first?.colorHex
                    map.addOverlay(line, level: .aboveRoads)
                }
            }
            if config.showBubbles || (config.showPath && !config.showHeat) {
                map.addAnnotations(config.points.indices.map { CmpMapAnnotation(index: $0, coordinate: config.points[$0].coordinate) })
            }
        }

        private func refreshAnnotationViews(_ map: MKMapView) {
            for a in map.annotations {
                guard let a = a as? CmpMapAnnotation, let v = map.view(for: a) as? CmpBubbleAnnotationView else { continue }
                configure(v, index: a.index)
            }
        }

        private func configure(_ view: CmpBubbleAnnotationView, index: Int) {
            guard var p = config.points[safe: index] else { return }
            if !config.showBubbles { p.radius = max(3, CGFloat(config.pathWidth) + 1.5) }   // path-only: small vertices
            view.configure(point: p, config: config, emphasis: config.emphasis[safe: index] ?? 1,
                           selected: config.selected[safe: index] ?? false, focused: config.focusedIndex == index)
        }

        /// Zooms to show every point with comfortable padding.
        func fit(_ map: MKMapView, animated: Bool) {
            guard let first = config.points.first else { return }
            var rect = MKMapRect(origin: MKMapPoint(first.coordinate), size: MKMapSize(width: 0, height: 0))
            for p in config.points.dropFirst() {
                rect = rect.union(MKMapRect(origin: MKMapPoint(p.coordinate), size: MKMapSize(width: 0, height: 0)))
            }
            if rect.size.width < 1 && rect.size.height < 1 {
                map.setRegion(MKCoordinateRegion(center: first.coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000), animated: animated)
                return
            }
            let maxR = (config.points.map(\.radius).max() ?? 10) + 14
            let pad = min(maxR, max(8, min(map.bounds.width, map.bounds.height) / 4))
            map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad), animated: animated)
        }

        private func screenPoints(in view: NSView) -> [CGPoint] {
            guard let map else { return [] }
            return config.points.map { map.convert($0.coordinate, toPointTo: view) }
        }

        private func renderHeat() {
            guard let heat, config.showHeat, heat.bounds.width > 0 else { heat?.image = nil; return }
            let pts = zip(screenPoints(in: heat), config.points).map { (p: $0, weight: $1.weight) }
            heat.image = CmpHeatmapRenderer.image(points: pts, size: heat.bounds.size, radius: config.heatRadius,
                                                  intensity: config.heatIntensity, ramp: config.heatRamp, opacity: config.heatOpacity)
        }

        private func finishMarquee(rect: CGRect?, lasso path: [CGPoint]?, additive: Bool) {
            guard let lasso else { return }
            let pts = screenPoints(in: lasso)
            let hits = rect.map { CmpMapHitTest.inRect($0, pts) } ?? CmpMapHitTest.inLasso(path ?? [], pts)
            if hits.isEmpty, additive { return }
            parent.onSelect(hits, additive)
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? CmpMapAnnotation else { return nil }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: "bubble", for: a)
            if let v = v as? CmpBubbleAnnotationView { configure(v, index: a.index) }
            // Larger bubbles sit behind smaller ones so nothing is hidden.
            v.zPriority = MKAnnotationViewZPriority(rawValue: Float(max(0, 1000 - (config.points[safe: a.index]?.radius ?? 0) * 10)))
            return v
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            mapView.deselectAnnotation(view.annotation, animated: false)
            guard config.interactive, let a = view.annotation as? CmpMapAnnotation else { return }
            parent.onSelect([a.index], NSEvent.modifierFlags.contains(.command))
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = CmpColor.ns(line.title ?? config.accentHex).withAlphaComponent(0.9)
            r.lineWidth = config.pathWidth
            r.lineJoin = .round; r.lineCap = .round
            return r
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) { if config.showHeat { renderHeat() } }

        // MARK: Background click clears the selection

        @objc func backgroundClick(_ g: NSClickGestureRecognizer) {
            guard config.interactive, config.mode == .pan, let map else { return }
            let p = g.location(in: map)
            var v = map.hitTest(map.superview?.convert(p, from: map) ?? p)
            while let cur = v {
                if cur is MKAnnotationView || cur is NSControl { return }
                v = cur.superview
            }
            if config.selected.contains(true), !NSEvent.modifierFlags.contains(.command) { parent.onSelect([], false) }
        }

        func gestureRecognizer(_ g: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool { true }
    }
}
