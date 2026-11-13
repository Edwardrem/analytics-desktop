import SwiftUI
import FacetCore
import FacetDesign

/// The diagram: relationship lines under the table cards, the line being dragged over them, and
/// the event layer on top. Everything is drawn from a `ModelDiagram.Scene`.
struct ModelCanvasView: View {
    @EnvironmentObject private var store: DocumentStore
    @ObservedObject var modeling: ModelingState
    @ObservedObject var controller: ModelCanvasController

    var body: some View {
        let scene = controller.scene(store)
        let viewport = ModelDiagram.Viewport(zoom: modeling.zoom, offset: modeling.offset)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Design.Palette.canvas
                if scene.cards.isEmpty { emptyLayout }
                Canvas { context, _ in drawEdges(scene, viewport, in: &context) }
                    .accessibilityHidden(true)
                ForEach(scene.cards) { card in
                    ModelCardView(card: card, selection: modeling.selection, target: linkTarget(for: card.table), source: linkSource(for: card.table))
                        .frame(width: card.frame.width, height: card.frame.height)
                        .scaleEffect(viewport.zoom, anchor: .topLeading)
                        .offset(x: card.frame.minX * viewport.zoom + viewport.offset.width,
                                y: card.frame.minY * viewport.zoom + viewport.offset.height)
                }
                Canvas { context, _ in drawLink(viewport, in: &context) }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                ModelCanvasEvents(controller: controller)
            }
            .clipped()
            .onAppear {
                controller.viewSize = geo.size
                // Fit the first time the diagram is shown; after that the user's pan and zoom stay.
                if modeling.zoom == 1, modeling.offset == .zero { fitSoon() }
            }
            .onChange(of: geo.size) { _, size in controller.viewSize = size }
            .onChange(of: modeling.fitRequest) { _, _ in controller.fit() }
            .onChange(of: modeling.layoutID) { _, _ in fitSoon() }
        }
    }

    /// Fits once the event layer has been laid out and reported its size.
    private func fitSoon() {
        DispatchQueue.main.async { controller.fit() }
    }

    private var emptyLayout: some View {
        EmptyState(systemImage: "rectangle.3.group", title: "Nothing on this layout yet",
                   message: "Drag tables here from the model explorer, or use Add table.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Relationship drag state

    private func linkTarget(for table: String) -> ModelCanvasController.LinkTarget? {
        guard case .link(_, _, _, _, let target?) = controller.gesture, ModelDAX.same(target.table, table) else { return nil }
        return target
    }
    private func linkSource(for table: String) -> String? {
        guard case .link(let t, let column, _, _, _) = controller.gesture, ModelDAX.same(t, table) else { return nil }
        return column
    }

    // MARK: Drawing

    private func drawEdges(_ scene: ModelDiagram.Scene, _ v: ModelDiagram.Viewport, in context: inout GraphicsContext) {
        for edge in scene.edges {
            let selected = modeling.isSelected(.relationship(edge.id))
            let colour: Color = selected ? Design.Palette.accent : Design.Palette.secondaryText
            let points = edge.points.map(v.toScreen)
            let style = StrokeStyle(lineWidth: selected ? 2 : 1.25, lineCap: .round, lineJoin: .round,
                                    dash: edge.isActive ? [] : [5, 4])
            context.stroke(Self.rounded(points, radius: 8 * v.zoom), with: .color(colour), style: style)
            drawArrows(edge, v, colour, in: &context)
            drawLabel(edge.fromLabel, at: v.toScreen(edge.fromLabelPoint), colour, in: &context)
            drawLabel(edge.toLabel, at: v.toScreen(edge.toLabelPoint), colour, in: &context)
        }
    }

    private func drawLabel(_ text: String, at point: CGPoint, _ colour: Color, in context: inout GraphicsContext) {
        let resolved = context.resolve(Text(text).font(Design.Typeface.captionStrong).foregroundStyle(colour))
        let size = resolved.measure(in: CGSize(width: 40, height: 40))
        let plate = CGRect(x: point.x - size.width / 2 - 2, y: point.y - size.height / 2, width: size.width + 4, height: size.height)
        context.fill(Path(roundedRect: plate, cornerRadius: 3), with: .color(Design.Palette.canvas))
        context.draw(resolved, at: point)
    }

    /// The cross-filter arrow(s) half way along the line: one pointing the way filters flow, or
    /// two back to back when they flow both ways.
    private func drawArrows(_ edge: ModelDiagram.Edge, _ v: ModelDiagram.Viewport, _ colour: Color, in context: inout GraphicsContext) {
        let centre = v.toScreen(edge.arrowPoint)
        let d = edge.arrowDirection
        func arrow(tip: CGPoint, along: CGVector) -> Path {
            let size: CGFloat = 6
            let back = CGPoint(x: tip.x - along.dx * size * 1.5, y: tip.y - along.dy * size * 1.5)
            var path = Path()
            path.move(to: tip)
            path.addLine(to: CGPoint(x: back.x - along.dy * size * 0.75, y: back.y + along.dx * size * 0.75))
            path.addLine(to: CGPoint(x: back.x + along.dy * size * 0.75, y: back.y - along.dx * size * 0.75))
            path.closeSubpath()
            return path
        }
        let forward = CGVector(dx: d.dx, dy: d.dy), backward = CGVector(dx: -d.dx, dy: -d.dy)
        switch edge.direction {
        case .towardTo:
            context.fill(arrow(tip: CGPoint(x: centre.x + d.dx * 4.5, y: centre.y + d.dy * 4.5), along: forward), with: .color(colour))
        case .towardFrom:
            context.fill(arrow(tip: CGPoint(x: centre.x - d.dx * 4.5, y: centre.y - d.dy * 4.5), along: backward), with: .color(colour))
        case .both:
            context.fill(arrow(tip: CGPoint(x: centre.x + d.dx * 10, y: centre.y + d.dy * 10), along: forward), with: .color(colour))
            context.fill(arrow(tip: CGPoint(x: centre.x - d.dx * 10, y: centre.y - d.dy * 10), along: backward), with: .color(colour))
        }
    }

    /// The line that follows the pointer while a column is dragged towards another table.
    private func drawLink(_ v: ModelDiagram.Viewport, in context: inout GraphicsContext) {
        guard case .link(_, _, let start, let point, let target) = controller.gesture else { return }
        let colour: Color = target?.problem != nil ? Design.Palette.negative : Design.Palette.accent
        var path = Path()
        path.move(to: v.toScreen(start))
        path.addLine(to: v.toScreen(point))
        context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
        let end = v.toScreen(point)
        context.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)), with: .color(colour))
    }

    /// A polyline with rounded corners.
    static func rounded(_ points: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for p in points.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let a = points[i - 1], b = points[i], c = points[i + 1]
            let r = min(radius, hypot(b.x - a.x, b.y - a.y) / 2, hypot(c.x - b.x, c.y - b.y) / 2)
            if r > 0.5 { path.addArc(tangent1End: b, tangent2End: c, radius: r) } else { path.addLine(to: b) }
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

/// One table card. It only draws: the event layer above the diagram handles every click and drag,
/// using the same `ModelDiagram` geometry this view lays its rows out with.
struct ModelCardView: View {
    let card: ModelDiagram.CardLayout
    let selection: [ModelObjectRef]
    /// The column a relationship drag is over, when it is in this card.
    let target: ModelCanvasController.LinkTarget?
    /// The column a relationship drag started from, when it is in this card.
    let source: String?

    private typealias Metrics = ModelDiagram.Metrics
    private var tableSelected: Bool { selection.contains(.table(card.table)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !card.collapsed {
                ForEach(card.fields) { field in row(field) }
                if card.overflow > 0 {
                    Text("\(card.overflow) more…")
                        .font(Design.Typeface.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, Design.Space.m)
                        .frame(maxWidth: .infinity, minHeight: Metrics.footer, maxHeight: Metrics.footer, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Palette.elevated)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            .strokeBorder(tableSelected ? Design.Palette.accent : Design.Palette.hairlineStrong, lineWidth: tableSelected ? 1.5 : 1))
        .overlay(alignment: .bottomTrailing) { if !card.collapsed { grip } }
        .shadow(color: Design.Palette.hairlineStrong, radius: tableSelected ? 6 : 3, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Table \(card.table), \(card.fields.count + card.overflow) fields\(card.collapsed ? ", collapsed" : "")")
        .accessibilityAddTraits(tableSelected ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: card.glyph).font(.system(size: 11)).foregroundStyle(Design.Palette.accent)
            Text(card.table).font(Design.Typeface.bodyStrong).lineLimit(1)
                .foregroundStyle(card.isHidden ? .secondary : .primary)
            if card.isHidden { Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.tertiary) }
            Spacer(minLength: 0)
            Image(systemName: card.collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: Metrics.toggle - Design.Space.s)
        }
        .padding(.leading, Design.Space.m)
        .padding(.trailing, Design.Space.xs)
        .frame(height: Metrics.header)
        .background(tableSelected ? Design.Palette.fillStrong : Design.Palette.fill)
        .overlay(alignment: .bottom) { if !card.collapsed { Hairline() } }
    }

    private func row(_ field: ModelDiagram.Field) -> some View {
        let selected = selection.contains(field.ref(in: card.table))
        let isTarget = field.kind == .column && target.map { ModelDAX.same($0.column, field.name) } == true
        let isSource = field.kind == .column && source.map { ModelDAX.same($0, field.name) } == true
        let fill: Color = isTarget ? (target?.problem == nil ? Design.Palette.accent.opacity(0.22) : Design.Palette.negative.opacity(0.22))
            : (selected || isSource) ? Design.Palette.accent.opacity(0.14) : .clear
        return HStack(spacing: Design.Space.xs) {
            Image(systemName: field.glyph).font(.system(size: 10))
                .foregroundStyle(field.isKey ? AnyShapeStyle(Design.Palette.caution)
                                 : field.isCalculated ? AnyShapeStyle(Design.Palette.accent) : AnyShapeStyle(.secondary))
                .frame(width: 14)
            Text(field.name).font(Design.Typeface.caption).lineLimit(1)
                .foregroundStyle(field.isHidden ? .secondary : .primary)
            Spacer(minLength: 0)
            if field.isHidden { Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, Design.Space.m)
        .frame(height: Metrics.row)
        .background(fill)
    }

    /// The resize corner: two short diagonal strokes.
    private var grip: some View {
        Path { p in
            p.move(to: CGPoint(x: 9, y: 3)); p.addLine(to: CGPoint(x: 3, y: 9))
            p.move(to: CGPoint(x: 9, y: 6.5)); p.addLine(to: CGPoint(x: 6.5, y: 9))
        }
        .stroke(Design.Palette.tertiaryText, lineWidth: 1)
        .frame(width: Metrics.handle, height: Metrics.handle)
    }
}
