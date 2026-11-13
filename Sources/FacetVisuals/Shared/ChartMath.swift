import Foundation
import CoreGraphics

/// Small numeric toolkit shared by the chart renderers: summary statistics, least-squares fit,
/// and the two down-sampling schemes used to keep dense charts responsive.
public enum ChartMath {
    public static func mean(_ v: [Double]) -> Double? {
        v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    /// Linear-interpolated percentile; `p` in 0…100.
    public static func percentile(_ v: [Double], _ p: Double) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        let pos = max(0, min(1, p / 100)) * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    public static func median(_ v: [Double]) -> Double? { percentile(v, 50) }

    /// Ordinary least-squares line through the points. Nil when fewer than two distinct x values.
    public static func linearRegression(_ pts: [(x: Double, y: Double)]) -> (slope: Double, intercept: Double)? {
        guard pts.count >= 2 else { return nil }
        let n = Double(pts.count)
        let sx = pts.reduce(0) { $0 + $1.x }, sy = pts.reduce(0) { $0 + $1.y }
        let sxx = pts.reduce(0) { $0 + $1.x * $1.x }, sxy = pts.reduce(0) { $0 + $1.x * $1.y }
        let d = n * sxx - sx * sx
        guard abs(d) > 1e-12 else { return nil }
        let slope = (n * sxy - sx * sy) / d
        return (slope, (sy - slope * sx) / n)
    }

    /// Largest-Triangle-Three-Buckets down-sampling. Returns the indices to keep (always first and last),
    /// preserving the visual shape of a line with at most `threshold` points.
    public static func lttb(_ pts: [(x: Double, y: Double)], threshold: Int) -> [Int] {
        let n = pts.count
        guard threshold >= 3, n > threshold else { return Array(0..<n) }
        var out = [0]
        out.reserveCapacity(threshold)
        let every = Double(n - 2) / Double(threshold - 2)
        var a = 0
        for i in 0..<(threshold - 2) {
            let nextStart = Int(Double(i + 1) * every) + 1
            let nextEnd = min(Int(Double(i + 2) * every) + 1, n)
            var ax = 0.0, ay = 0.0
            let cnt = Double(max(1, nextEnd - nextStart))
            for j in nextStart..<max(nextStart + 1, nextEnd) where j < n { ax += pts[j].x; ay += pts[j].y }
            ax /= cnt; ay /= cnt
            let start = Int(Double(i) * every) + 1
            let end = min(Int(Double(i + 1) * every) + 1, n - 1)
            var best = start, bestArea = -1.0
            for j in start..<max(start + 1, end) {
                let area = abs((pts[a].x - ax) * (pts[j].y - pts[a].y) - (pts[a].x - pts[j].x) * (ay - pts[a].y))
                if area > bestArea { bestArea = area; best = j }
            }
            out.append(best); a = best
        }
        out.append(n - 1)
        return out
    }

    /// High-density sampling for scatter plots: overlays a grid and keeps one representative per occupied
    /// cell, so isolated points (outliers) always survive while dense regions thin out. Returns kept indices.
    public static func densitySample(_ pts: [(x: Double, y: Double)], maxCount: Int) -> [Int] {
        guard pts.count > maxCount, maxCount > 0 else { return Array(pts.indices) }
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        let w = max(maxX - minX, 1e-12), h = max(maxY - minY, 1e-12)
        var grid = max(4, Int((Double(maxCount)).squareRoot() * 2))
        while true {
            var seen = [Int: Int]()
            seen.reserveCapacity(maxCount)
            for (i, p) in pts.enumerated() {
                let cx = min(grid - 1, Int((p.x - minX) / w * Double(grid)))
                let cy = min(grid - 1, Int((p.y - minY) / h * Double(grid)))
                let key = cy * grid + cx
                if seen[key] == nil { seen[key] = i }
            }
            if seen.count <= maxCount || grid <= 4 { return seen.values.sorted() }
            grid = Int(Double(grid) * 0.8)
        }
    }
}
