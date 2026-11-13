// Draws Facet's app icon at every required size into an .iconset folder.
// Usage: swift Scripts/make-icon.swift <output.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Facet.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px)
    // macOS icon grid: the tile occupies ~80% of the canvas with a soft shadow.
    let inset = s * 0.1
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.2237
    let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space, colors: [NSColor(white: 1, alpha: 1).cgColor, NSColor(white: 0.93, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    // The mark: a single cut gem seen from above — four facets, one accent.
    let c = CGPoint(x: tile.midX, y: tile.midY)
    let r = tile.width * 0.30
    let top = CGPoint(x: c.x, y: c.y + r), right = CGPoint(x: c.x + r, y: c.y), bottom = CGPoint(x: c.x, y: c.y - r), left = CGPoint(x: c.x - r, y: c.y)
    func facet(_ a: CGPoint, _ b: CGPoint, _ color: NSColor) {
        ctx.beginPath(); ctx.move(to: c); ctx.addLine(to: a); ctx.addLine(to: b); ctx.closePath()
        ctx.setFillColor(color.cgColor); ctx.fillPath()
    }
    facet(top, right, NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1))
    facet(right, bottom, NSColor(srgbRed: 0.02, green: 0.36, blue: 0.84, alpha: 1))
    facet(bottom, left, NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
    facet(left, top, NSColor(srgbRed: 0.36, green: 0.69, blue: 1.00, alpha: 1))
    ctx.restoreGState()
    // Hairline edge.
    ctx.addPath(path); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.08).cgColor); ctx.setLineWidth(max(1, s / 512)); ctx.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("Wrote \(out)")
