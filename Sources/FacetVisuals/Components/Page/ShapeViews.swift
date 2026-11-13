import SwiftUI
import AppKit
import FacetCore
import FacetDesign

// MARK: - Image source

/// Draws an image from embedded bytes or a reference string: http(s) URL, `file://` URL / absolute path,
/// or a `data:` URI. Scaling: "fit" (aspect fit), "fill" (aspect fill, clipped), "normal" (natural size,
/// centred, clipped), "stretch".
struct CmpImageSource: View {
    let data: Data?
    let reference: String
    var scaling: String = "fit"
    var theme: ThemeSpec = .facet

    /// Synchronously resolvable image: embedded bytes, data URI or local file.
    static func localImage(data: Data?, reference: String) -> NSImage? {
        if let data, let img = NSImage(data: data) { return img }
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if ref.hasPrefix("data:"), let comma = ref.firstIndex(of: ",") {
            let header = ref[..<comma], payload = String(ref[ref.index(after: comma)...])
            let bytes = header.contains(";base64") ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
                : payload.removingPercentEncoding?.data(using: .utf8)
            return bytes.flatMap(NSImage.init(data:))
        }
        if ref.hasPrefix("file://"), let url = URL(string: ref) { return NSImage(contentsOf: url) }
        if ref.hasPrefix("/") { return NSImage(contentsOfFile: ref) }
        return nil
    }
    static func remoteURL(_ reference: String) -> URL? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: ref), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }
    static func hasSource(data: Data?, reference: String) -> Bool {
        localImage(data: data, reference: reference) != nil || remoteURL(reference) != nil
    }

    var body: some View {
        if let ns = Self.localImage(data: data, reference: reference) {
            scaled(Image(nsImage: ns), natural: ns.size)
        } else if let url = Self.remoteURL(reference) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): scaled(image, natural: nil)
                case .failure: missing("exclamationmark.triangle")
                default: ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            missing("photo")
        }
    }

    @ViewBuilder private func scaled(_ image: Image, natural: CGSize?) -> some View {
        switch scaling {
        case "fill":
            GeometryReader { geo in
                image.resizable().aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height).clipped()
            }
        case "stretch":
            image.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
        case "normal":
            GeometryReader { geo in
                image.frame(width: geo.size.width, height: geo.size.height).clipped()
            }
        default:
            image.resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func missing(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .light)).foregroundStyle(theme.secondaryColor.opacity(0.7))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Image visual

struct CmpImageVisualView: View {
    let env: CmpEnv
    @State private var hovering = false

    var body: some View {
        let action = env.spec.action
        let hasAction = (action?.kind ?? ActionSpec.Kind.none) != ActionSpec.Kind.none
        if CmpImageSource.hasSource(data: env.spec.imageData, reference: env.spec.content) {
            CmpImageSource(data: env.spec.imageData, reference: env.spec.content,
                           scaling: env.f.string("image", "scaling", "fit"), theme: env.theme)
                .opacity(1 - env.f.double("image", "transparency", 0) / 100)
                .clipShape(RoundedRectangle(cornerRadius: CGFloat(env.f.double("image", "radius", 0)), style: .continuous))
                .opacity(hasAction && hovering ? 0.88 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture { if hasAction, env.isInteractive, let action { env.context.onAction(action) } }
                .help(action?.tooltip.isEmpty == false ? action?.tooltip ?? "" : env.spec.altText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(env.spec.altText.isEmpty ? env.spec.name : env.spec.altText)
                .accessibilityAddTraits(hasAction ? [.isImage, .isButton] : .isImage)
        } else {
            CmpPlaceholder(systemImage: "photo", title: "Image", message: "Choose an image file or enter an image URL.", theme: env.theme)
        }
    }
}

// MARK: - Shape geometry

/// Every shape kind accepted in `format["shape"]["kind"]`.
enum CmpShapeKind: String, CaseIterable {
    case rectangle, roundedRectangle, ellipse, triangle, rightTriangle, diamond, pentagon, hexagon, octagon
    case arrow, chevron, speechBubble, heart, star, pill, line
}

struct CmpShapePath: InsettableShape {
    var kind: CmpShapeKind
    var cornerRadius: CGFloat = 12
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> CmpShapePath {
        var s = self; s.inset += amount; return s
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        func polygon(_ pts: [CGPoint]) -> Path {
            var p = Path()
            guard let first = pts.first else { return p }
            p.move(to: first); pts.dropFirst().forEach { p.addLine(to: $0) }; p.closeSubpath()
            return p
        }
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        /// Regular polygon / star stretched to fill the rect exactly.
        func radial(_ n: Int, innerRatio: CGFloat? = nil, rotation: CGFloat = -.pi / 2) -> Path {
            var raw: [CGPoint] = []
            let count = innerRatio == nil ? n : n * 2
            for i in 0..<count {
                let a = rotation + CGFloat(i) * 2 * .pi / CGFloat(count)
                let rad: CGFloat = (innerRatio != nil && i % 2 == 1) ? innerRatio! : 1
                raw.append(CGPoint(x: cos(a) * rad, y: sin(a) * rad))
            }
            let xs = raw.map(\.x), ys = raw.map(\.y)
            let minX = xs.min() ?? -1, maxX = xs.max() ?? 1, minY = ys.min() ?? -1, maxY = ys.max() ?? 1
            return polygon(raw.map { pt(($0.x - minX) / (maxX - minX), ($0.y - minY) / (maxY - minY)) })
        }
        switch kind {
        case .rectangle, .line: return Path(r)
        case .roundedRectangle:
            return Path(roundedRect: r, cornerRadius: min(cornerRadius, min(r.width, r.height) / 2), style: .continuous)
        case .pill: return Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2, style: .continuous)
        case .ellipse: return Path(ellipseIn: r)
        case .triangle: return polygon([pt(0.5, 0), pt(1, 1), pt(0, 1)])
        case .rightTriangle: return polygon([pt(0, 0), pt(1, 1), pt(0, 1)])
        case .diamond: return polygon([pt(0.5, 0), pt(1, 0.5), pt(0.5, 1), pt(0, 0.5)])
        case .pentagon: return radial(5)
        case .hexagon: return radial(6, rotation: 0)
        case .octagon: return radial(8, rotation: .pi / 8)
        case .star: return radial(5, innerRatio: 0.45)
        case .arrow:
            let head = min(r.height * 0.9, r.width * 0.45) / r.width
            return polygon([pt(0, 0.28), pt(1 - head, 0.28), pt(1 - head, 0), pt(1, 0.5), pt(1 - head, 1), pt(1 - head, 0.72), pt(0, 0.72)])
        case .chevron:
            let d = min(r.height / 2, r.width * 0.35) / r.width
            return polygon([pt(0, 0), pt(1 - d, 0), pt(1, 0.5), pt(1 - d, 1), pt(0, 1), pt(d, 0.5)])
        case .speechBubble:
            let bodyH = r.height * 0.78
            let body = CGRect(x: r.minX, y: r.minY, width: r.width, height: bodyH)
            let rad = min(cornerRadius, min(body.width, body.height) / 2)
            let tailW = min(r.width * 0.16, r.height * 0.3)
            let tailX = r.minX + max(rad, r.width * 0.16)
            var p = Path()
            p.move(to: CGPoint(x: body.minX + rad, y: body.minY))
            p.addLine(to: CGPoint(x: body.maxX - rad, y: body.minY))
            p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY + rad), radius: rad)
            p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - rad))
            p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - rad, y: body.maxY), radius: rad)
            p.addLine(to: CGPoint(x: tailX + tailW, y: body.maxY))
            p.addLine(to: CGPoint(x: tailX - tailW * 0.25, y: r.maxY))
            p.addLine(to: CGPoint(x: tailX, y: body.maxY))
            p.addLine(to: CGPoint(x: body.minX + rad, y: body.maxY))
            p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - rad), radius: rad)
            p.addLine(to: CGPoint(x: body.minX, y: body.minY + rad))
            p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX + rad, y: body.minY), radius: rad)
            p.closeSubpath()
            return p
        case .heart:
            var p = Path()
            p.move(to: pt(0.5, 1))
            p.addCurve(to: pt(0, 0.3), control1: pt(0.18, 0.78), control2: pt(0, 0.56))
            p.addCurve(to: pt(0.5, 0.2), control1: pt(0, -0.06), control2: pt(0.42, -0.06))
            p.addCurve(to: pt(1, 0.3), control1: pt(0.58, -0.06), control2: pt(1, -0.06))
            p.addCurve(to: pt(0.5, 1), control1: pt(1, 0.56), control2: pt(0.82, 0.78))
            p.closeSubpath()
            return p
        }
    }
}

// MARK: - Shape visual

struct CmpShapeView: View {
    let env: CmpEnv

    var body: some View {
        let f = env.f
        let kind = CmpShapeKind(rawValue: f.string("shape", "kind", "rectangle")) ?? .rectangle
        let fillHex = f.string("fill", "color", env.theme.dataColors.first ?? env.theme.accent)
        let fill = Color(hex: fillHex).opacity(1 - f.double("fill", "transparency", 0) / 100)
        let showFill = f.bool("fill", "show", true)
        let showOutline = f.bool("outline", "show", kind == .line)
        let outlineColor = f.color("outline", "color", kind == .line ? env.theme.foreground : env.theme.gridline)
        let lineWidth = CGFloat(f.double("outline", "width", kind == .line ? 2 : 1))
        let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: dash(f.string("outline", "style", "solid"), lineWidth))
        let shape = CmpShapePath(kind: kind, cornerRadius: CGFloat(f.double("shape", "cornerRadius", 12)))
        let action = env.spec.action
        let hasAction = (action?.kind ?? ActionSpec.Kind.none) != ActionSpec.Kind.none
        let text = f.string("text", "text", "")
        ZStack {
            if kind == .line {
                CmpLinePath(direction: f.string("shape", "lineDirection", "auto"),
                            startCap: f.string("shape", "startCap", "none"), endCap: f.string("shape", "endCap", "none"),
                            lineWidth: lineWidth)
                    .stroke(outlineColor, style: stroke)
            } else {
                if showFill { shape.fill(fill) }
                if showOutline { shape.strokeBorder(outlineColor, style: stroke) }
            }
            if !text.isEmpty, kind != .line {
                let textHex = f.string("text", "color", showFill ? CmpColor.readableText(on: fillHex) : env.theme.foreground)
                GeometryReader { geo in
                    let bodyH = kind == .speechBubble ? geo.size.height * 0.78 : geo.size.height
                    Text(text)
                        .font(env.font(f.double("text", "size", 13), f.bool("text", "bold", false) ? .semibold : .regular))
                        .foregroundStyle(Color(hex: textHex))
                        .multilineTextAlignment(alignment(f.string("text", "alignment", "center")))
                        .minimumScaleFactor(0.6)
                        .padding(CGFloat(f.double("text", "padding", 8)))
                        .frame(width: geo.size.width, height: bodyH,
                               alignment: Alignment(horizontal: horizontal(f.string("text", "alignment", "center")), vertical: .center))
                }
            }
        }
        .shadow(color: f.bool("shape", "shadow", false) ? .black.opacity(env.theme.isDark ? 0.5 : 0.18) : .clear, radius: 8, y: 3)
        .rotationEffect(.degrees(env.spec.frame.rotation))
        .contentShape(Rectangle())
        .onTapGesture { if hasAction, env.isInteractive, let action { env.context.onAction(action) } }
        .help(action?.tooltip ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(env.spec.altText.isEmpty ? (text.isEmpty ? "\(kind.rawValue) shape" : text) : env.spec.altText)
        .accessibilityAddTraits(hasAction ? .isButton : .isImage)
    }

    private func dash(_ style: String, _ w: CGFloat) -> [CGFloat] {
        switch style {
        case "dashed": return [w * 4, w * 3]
        case "dotted": return [0.01, w * 2.2]
        default: return []
        }
    }
    private func alignment(_ s: String) -> TextAlignment { s == "left" ? .leading : (s == "right" ? .trailing : .center) }
    private func horizontal(_ s: String) -> HorizontalAlignment { s == "left" ? .leading : (s == "right" ? .trailing : .center) }
}

/// A straight line across the frame with optional arrow / dot end caps.
struct CmpLinePath: Shape {
    var direction: String
    var startCap: String
    var endCap: String
    var lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let m = max(lineWidth, 1) * 2.5
        let r = rect.insetBy(dx: min(m, rect.width / 3), dy: min(m, rect.height / 3))
        var a: CGPoint, b: CGPoint
        switch direction == "auto" ? (rect.height > rect.width * 1.5 ? "vertical" : "horizontal") : direction {
        case "vertical": a = CGPoint(x: rect.midX, y: r.minY); b = CGPoint(x: rect.midX, y: r.maxY)
        case "diagonalDown": a = CGPoint(x: r.minX, y: r.minY); b = CGPoint(x: r.maxX, y: r.maxY)
        case "diagonalUp": a = CGPoint(x: r.minX, y: r.maxY); b = CGPoint(x: r.maxX, y: r.minY)
        default: a = CGPoint(x: r.minX, y: rect.midY); b = CGPoint(x: r.maxX, y: rect.midY)
        }
        var p = Path()
        p.move(to: a); p.addLine(to: b)
        cap(&p, at: a, from: b, kind: startCap)
        cap(&p, at: b, from: a, kind: endCap)
        return p
    }

    private func cap(_ p: inout Path, at tip: CGPoint, from other: CGPoint, kind: String) {
        let size = max(6, lineWidth * 4)
        let angle = atan2(tip.y - other.y, tip.x - other.x)
        switch kind {
        case "arrow":
            for side in [-1.0, 1.0] {
                let a = angle + .pi + CGFloat(side) * .pi / 7
                p.move(to: tip)
                p.addLine(to: CGPoint(x: tip.x + cos(a) * size, y: tip.y + sin(a) * size))
            }
        case "dot":
            let d = max(3, lineWidth * 1.5)
            p.addEllipse(in: CGRect(x: tip.x - d / 2, y: tip.y - d / 2, width: d, height: d))
        default: break
        }
    }
}
