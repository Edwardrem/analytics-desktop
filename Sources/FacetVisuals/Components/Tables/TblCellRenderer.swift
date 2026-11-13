import AppKit
import FacetCore

/// Draws grid cells with AppKit primitives (fast enough to repaint every visible cell per frame).
enum CmpTblCellRenderer {
    private static let paragraphs: [NSParagraphStyle] = {
        // index = alignment (0 left, 1 center, 2 right) + (wrap ? 3 : 0)
        var out: [NSParagraphStyle] = []
        for wrap in [false, true] {
            for a in [NSTextAlignment.left, .center, .right] {
                let p = NSMutableParagraphStyle()
                p.alignment = a
                p.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
                out.append(p)
            }
        }
        return out
    }()
    private static func paragraph(_ a: NSTextAlignment, wrap: Bool) -> NSParagraphStyle {
        let i = a == .right ? 2 : (a == .center ? 1 : 0)
        return paragraphs[i + (wrap ? 3 : 0)]
    }

    static let expanderWidth: CGFloat = 16

    static func font(_ cell: CmpTblCell, _ style: CmpTblStyle) -> NSFont {
        cell.isHeader ? style.headerFont : (cell.bold ? style.bodyBoldFont : style.bodyFont)
    }

    /// Rect available for text after padding, indent and expander.
    static func contentRect(_ cell: CmpTblCell, _ rect: CGRect, _ style: CmpTblStyle) -> CGRect {
        var r = rect.insetBy(dx: style.padH, dy: 0)
        r.origin.x += cell.indent; r.size.width -= cell.indent
        if cell.expander != nil { r.origin.x += expanderWidth; r.size.width -= expanderWidth }
        return r
    }

    /// True when the cell's text does not fit on its line(s) — used for hover tooltips.
    static func isTruncated(_ cell: CmpTblCell, _ rect: CGRect, _ style: CmpTblStyle) -> Bool {
        guard !cell.text.isEmpty, cell.spark == nil, cell.imageRef == nil else { return false }
        var r = contentRect(cell, rect, style)
        if cell.icon != nil { r.size.width -= 16 }
        let f = font(cell, style)
        let w = CmpFit.width(displayText(cell, style), font: f)
        if cell.wrap {
            let lines = max(1, floor(rect.height / CmpTblStyle.lineHeight(f)))
            return w > r.width * lines * 0.92
        }
        return w > r.width + 0.5
    }

    private static func displayText(_ cell: CmpTblCell, _ style: CmpTblStyle) -> String {
        var t = cell.isHeader && style.uppercaseHeader ? cell.text.uppercased() : cell.text
        if let g = cell.sortGlyph { t = cell.align == .right ? g + " " + t : t + " " + g }
        return t
    }

    static func draw(_ cell: CmpTblCell, in rect: CGRect, style: CmpTblStyle, defaultText: NSColor) {
        if let bg = cell.background { bg.setFill(); rect.fill() }
        if cell.selected {
            style.selection.setFill(); rect.fill()
            style.accent.setStroke()
            let p = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
        }
        var r = rect.insetBy(dx: style.padH, dy: 0)
        r.origin.x += cell.indent; r.size.width -= cell.indent
        guard r.width > 2 else { return }
        if let expanded = cell.expander {
            drawExpander(expanded, at: CGPoint(x: r.minX + 5.5, y: rect.midY), color: defaultText.withAlphaComponent(0.62))
            r.origin.x += expanderWidth; r.size.width -= expanderWidth
        }
        if let ref = cell.imageRef, !ref.isEmpty {
            if let img = CmpTblImageCache.shared.image(ref) { drawImage(img, in: r.insetBy(dx: 0, dy: 3), align: cell.align) }
            else { drawPlaceholderImage(in: r.insetBy(dx: 0, dy: 3), align: cell.align, color: style.grid) }
            return
        }
        if let spark = cell.spark {
            drawSpark(spark, columns: cell.sparkColumns, in: r.insetBy(dx: 0, dy: max(4, rect.height * 0.2)),
                      color: style.accent.cmpDimmed(cell.dimmed))
            return
        }
        if let bar = cell.bar {
            let inset = max(3, floor(rect.height * 0.2))
            let track = r.insetBy(dx: 0, dy: inset)
            let x0 = track.minX + track.width * bar.start, x1 = track.minX + track.width * bar.end
            let barRect = CGRect(x: x0, y: track.minY, width: max(1, x1 - x0), height: track.height)
            CmpColor.ns(bar.colorHex).withAlphaComponent((cell.barOnly ? 0.85 : style.barAlpha) * (cell.dimmed ? 0.5 : 1)).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()
            if bar.axis > 0.001, bar.axis < 0.999 {
                style.strongGrid.setFill()
                CGRect(x: track.minX + track.width * bar.axis - 0.5, y: rect.minY + 2, width: 1, height: rect.height - 4).fill()
            }
            if cell.barOnly { return }
        }
        if let icon = cell.icon {
            let size = min(13, max(9, style.bodyFont.pointSize - 0.5))
            if let img = symbol(icon.symbol, color: icon.color, size: size) {
                let s = img.size
                if cell.iconOnly {
                    let x = cell.align == .right ? r.maxX - s.width : (cell.align == .center ? r.midX - s.width / 2 : r.minX)
                    img.draw(in: CGRect(x: x, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                             from: .zero, operation: .sourceOver, fraction: cell.dimmed ? 0.45 : 1, respectFlipped: true, hints: nil)
                    return
                }
                let slot: CGFloat = 16
                let x = cell.iconTrailing ? r.maxX - (slot + s.width) / 2 : r.minX + (slot - s.width) / 2
                img.draw(in: CGRect(x: x, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                         from: .zero, operation: .sourceOver, fraction: cell.dimmed ? 0.45 : 1, respectFlipped: true, hints: nil)
                if !cell.iconTrailing { r.origin.x += slot + 2 }
                r.size.width -= slot + 2
            }
        }
        let text = displayText(cell, style)
        guard !text.isEmpty, r.width > 2 else { return }
        let f = font(cell, style)
        var color = cell.textColor ?? defaultText
        var attrs: [NSAttributedString.Key: Any] = [.font: f, .paragraphStyle: paragraph(cell.align, wrap: cell.wrap)]
        if cell.link != nil {
            color = cell.textColor ?? style.link
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = color.withAlphaComponent(0.4)
        }
        attrs[.foregroundColor] = color.cmpDimmed(cell.dimmed)
        let lh = CmpTblStyle.lineHeight(f)
        if cell.wrap {
            let maxLines = max(1, floor((rect.height - 2) / lh))
            let needed = (text as NSString).boundingRect(with: CGSize(width: r.width, height: lh * maxLines),
                                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            let h = min(ceil(needed.height), lh * maxLines)
            (text as NSString).draw(with: CGRect(x: r.minX, y: rect.midY - h / 2, width: r.width, height: h),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        } else {
            (text as NSString).draw(with: CGRect(x: r.minX, y: rect.midY - lh / 2, width: r.width, height: lh),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }

    /// A small square +/− glyph.
    private static func drawExpander(_ expanded: Bool, at c: CGPoint, color: NSColor) {
        let box = CGRect(x: floor(c.x - 5) + 0.5, y: floor(c.y - 5) + 0.5, width: 10, height: 10)
        color.withAlphaComponent(color.alphaComponent * 0.55).setStroke()
        let outline = NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1; outline.stroke()
        color.setStroke()
        let p = NSBezierPath(); p.lineWidth = 1.2
        p.move(to: CGPoint(x: box.minX + 2.5, y: box.midY)); p.line(to: CGPoint(x: box.maxX - 2.5, y: box.midY))
        if !expanded { p.move(to: CGPoint(x: box.midX, y: box.minY + 2.5)); p.line(to: CGPoint(x: box.midX, y: box.maxY - 2.5)) }
        p.stroke()
    }

    private static func aligned(_ size: CGSize, in r: CGRect, align: NSTextAlignment) -> CGRect {
        let x = align == .right ? r.maxX - size.width : (align == .center ? r.midX - size.width / 2 : r.minX)
        return CGRect(x: x, y: r.midY - size.height / 2, width: size.width, height: size.height)
    }
    private static func drawImage(_ img: NSImage, in r: CGRect, align: NSTextAlignment) {
        guard img.size.width > 0, img.size.height > 0, r.width > 0, r.height > 0 else { return }
        let k = min(r.width / img.size.width, r.height / img.size.height)
        let target = aligned(CGSize(width: img.size.width * k, height: img.size.height * k), in: r, align: align)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: target, xRadius: 3, yRadius: 3).addClip()
        img.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }
    private static func drawPlaceholderImage(in r: CGRect, align: NSTextAlignment, color: NSColor) {
        let side = min(r.height, r.width)
        color.setFill()
        NSBezierPath(roundedRect: aligned(CGSize(width: side, height: side), in: r, align: align), xRadius: 3, yRadius: 3).fill()
    }

    private static func drawSpark(_ values: [Double], columns: Bool, in r: CGRect, color: NSColor) {
        guard !values.isEmpty, r.width > 4, r.height > 2 else { return }
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        if columns {
            let base = min(lo, 0), top = max(hi, 0)
            let span = top > base ? top - base : 1
            let slot = r.width / CGFloat(values.count)
            let bw = max(1, min(slot * 0.7, 8))
            let zeroY = r.maxY - CGFloat((0 - base) / span) * r.height
            for (i, v) in values.enumerated() {
                let y = r.maxY - CGFloat((v - base) / span) * r.height
                let rect = CGRect(x: r.minX + slot * CGFloat(i) + (slot - bw) / 2, y: min(y, zeroY), width: bw, height: max(1, abs(zeroY - y)))
                color.withAlphaComponent(color.alphaComponent * (v < 0 ? 0.45 : 0.8)).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            }
            return
        }
        let span = hi > lo ? hi - lo : 1
        func pt(_ i: Int) -> CGPoint {
            let x = values.count > 1 ? r.minX + 2 + (r.width - 4) * CGFloat(i) / CGFloat(values.count - 1) : r.midX
            let t = hi > lo ? (values[i] - lo) / span : 0.5
            return CGPoint(x: x, y: r.maxY - CGFloat(t) * r.height)
        }
        let path = NSBezierPath()
        path.lineWidth = 1.4; path.lineJoinStyle = .round; path.lineCapStyle = .round
        path.move(to: pt(0))
        for i in 1..<max(1, values.count) { path.line(to: pt(i)) }
        if values.count > 1 { color.setStroke(); path.stroke() }
        let last = pt(values.count - 1)
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)).fill()
    }

    // MARK: Symbols

    private static var symbolCache: [String: NSImage] = [:]
    static func symbol(_ name: String, color: String, size: CGFloat) -> NSImage? {
        let key = "\(name)|\(color)|\(size)"
        if let c = symbolCache[key] { return c }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [CmpColor.ns(color)]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: name)?.withSymbolConfiguration(config) else { return nil }
        symbolCache[key] = img
        return img
    }

    /// Parses the sparkline cell contract: a delimited numeric string such as "1|2|3" (also `,` `;` or spaces).
    static func parseSpark(_ v: Value) -> [Double]? {
        guard case .string(let s) = v else { return nil }
        let parts = s.split(whereSeparator: { $0 == "|" || $0 == ";" || $0 == "," || $0 == " " })
        let nums = parts.compactMap { Double($0) }
        return nums.isEmpty || nums.count != parts.count ? nil : nums
    }
}

/// Loads and caches cell images from http(s)/file URLs and `data:` URIs.
final class CmpTblImageCache {
    static let shared = CmpTblImageCache()
    static let didLoad = Notification.Name("CmpTblImageCacheDidLoad")
    private var images: [String: NSImage] = [:]
    private var pending: Set<String> = []
    private var failed: Set<String> = []

    /// Returns the image when available; otherwise starts loading (posting `didLoad` on the main queue when done).
    func image(_ ref: String) -> NSImage? {
        if let i = images[ref] { return i }
        if failed.contains(ref) || pending.contains(ref) { return nil }
        if ref.hasPrefix("data:") {
            if let comma = ref.firstIndex(of: ","), ref[..<comma].contains("base64"),
               let d = Data(base64Encoded: String(ref[ref.index(after: comma)...]), options: .ignoreUnknownCharacters),
               let img = NSImage(data: d) { images[ref] = img; return img }
            failed.insert(ref); return nil
        }
        guard let url = URL(string: ref), let scheme = url.scheme?.lowercased() else { failed.insert(ref); return nil }
        if scheme == "file" {
            if let img = NSImage(contentsOf: url) { images[ref] = img; return img }
            failed.insert(ref); return nil
        }
        guard scheme == "http" || scheme == "https" else { failed.insert(ref); return nil }
        pending.insert(ref)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let img = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                self.pending.remove(ref)
                if let img { self.images[ref] = img } else { self.failed.insert(ref) }
                NotificationCenter.default.post(name: CmpTblImageCache.didLoad, object: nil)
            }
        }.resume()
        return nil
    }
}
