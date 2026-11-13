import Foundation
import FacetCore

/// Result of a clustering run.
public struct ClusterResult: Sendable {
    /// Cluster index per input point (0-based). DBSCAN marks noise as −1.
    public var assignments: [Int]
    /// Cluster centres in the original (unstandardised) units.
    public var centroids: [[Double]]
    public var k: Int
    /// Mean silhouette coefficient (−1…1); 0 when undefined (a single cluster).
    public var silhouette: Double
    /// Within-cluster sum of squared distances in standardised space.
    public var inertia: Double
    /// Number of points per cluster.
    public var sizes: [Int]
}

public enum ClusteringError: LocalizedError {
    case noData
    case raggedInput
    public var errorDescription: String? {
        switch self {
        case .noData: return "Clustering needs at least two data points with numeric values."
        case .raggedInput: return "Every point must have the same number of numeric values."
        }
    }
}

/// k-means++ clustering with automatic choice of k.
public enum KMeans {
    /// Clusters `points` (one row of coordinates per point).
    /// - Parameters:
    ///   - k: number of clusters; nil picks the k in 2…maxK with the best silhouette.
    ///   - standardize: z-score each dimension first so scales are comparable.
    ///   - seed: seed of the deterministic generator; the same input and seed always give the same result.
    public static func cluster(points: [[Double]], k: Int? = nil, maxK: Int = 10, standardize: Bool = true,
                               seed: UInt64 = 42, maxIterations: Int = 100, restarts: Int = 4) throws -> ClusterResult {
        guard points.count >= 2, let dims = points.first?.count, dims > 0 else { throw ClusteringError.noData }
        guard points.allSatisfy({ $0.count == dims }) else { throw ClusteringError.raggedInput }
        let (z, means, sds) = Clustering.standardise(points, enabled: standardize)
        let distinct = Set(z.map { $0.map { ($0 * 1e9).rounded() } }).count
        func finish(_ run: Run) -> ClusterResult {
            let cents = run.centroids.map { c in (0..<dims).map { c[$0] * sds[$0] + means[$0] } }
            var sizes = [Int](repeating: 0, count: run.centroids.count)
            for a in run.assignments { sizes[a] += 1 }
            return ClusterResult(assignments: run.assignments, centroids: cents, k: run.centroids.count,
                                 silhouette: run.silhouette, inertia: run.inertia, sizes: sizes)
        }
        if let k {
            let kk = max(1, min(k, distinct))
            var run = best(z, k: kk, seed: seed, maxIterations: maxIterations, restarts: restarts)
            run.silhouette = Clustering.silhouette(z, assignments: run.assignments, k: kk, seed: seed)
            return finish(run)
        }
        let upper = min(maxK, distinct, points.count - 1)
        guard upper >= 2 else { return finish(best(z, k: 1, seed: seed, maxIterations: maxIterations, restarts: 1)) }
        var chosen: Run?
        for kk in 2...upper {
            var run = best(z, k: kk, seed: seed, maxIterations: maxIterations, restarts: restarts)
            run.silhouette = Clustering.silhouette(z, assignments: run.assignments, k: kk, seed: seed)
            if chosen == nil || run.silhouette > chosen!.silhouette + 1e-9 { chosen = run }
        }
        return finish(chosen!)
    }

    struct Run { var assignments: [Int]; var centroids: [[Double]]; var inertia: Double; var silhouette: Double = 0 }

    static func best(_ z: [[Double]], k: Int, seed: UInt64, maxIterations: Int, restarts: Int) -> Run {
        var bestRun: Run?
        for r in 0..<max(1, restarts) {
            var rng = SeededGenerator(seed: seed &+ UInt64(r) &* 7919 &+ UInt64(k) &* 104729)
            let run = lloyd(z, k: k, rng: &rng, maxIterations: maxIterations)
            if bestRun == nil || run.inertia < bestRun!.inertia - 1e-12 { bestRun = run }
        }
        // Relabel clusters by descending size for stable output.
        var run = bestRun!
        var sizes = [Int](repeating: 0, count: k)
        for a in run.assignments { sizes[a] += 1 }
        let order = (0..<k).sorted { sizes[$0] != sizes[$1] ? sizes[$0] > sizes[$1] : run.centroids[$0].lexicographicallyPrecedes(run.centroids[$1]) }
        var remap = [Int](repeating: 0, count: k)
        for (newIdx, old) in order.enumerated() { remap[old] = newIdx }
        run.assignments = run.assignments.map { remap[$0] }
        run.centroids = order.map { run.centroids[$0] }
        return run
    }

    static func lloyd(_ z: [[Double]], k: Int, rng: inout SeededGenerator, maxIterations: Int) -> Run {
        let n = z.count, dims = z[0].count
        // k-means++ seeding.
        var centroids: [[Double]] = [z[Int(rng.unit() * Double(n)) % n]]
        var d2 = z.map { Clustering.dist2($0, centroids[0]) }
        while centroids.count < k {
            let total = d2.reduce(0, +)
            var pick = 0
            if total > 0 {
                var target = rng.unit() * total
                for i in 0..<n { target -= d2[i]; if target <= 0 { pick = i; break }; pick = i }
            } else { pick = Int(rng.unit() * Double(n)) % n }
            centroids.append(z[pick])
            for i in 0..<n { d2[i] = min(d2[i], Clustering.dist2(z[i], z[pick])) }
        }
        var assign = [Int](repeating: -1, count: n)
        var inertia = 0.0
        for _ in 0..<max(1, maxIterations) {
            var changed = false
            inertia = 0
            for i in 0..<n {
                var bestC = 0, bestD = Double.infinity
                for c in 0..<k { let d = Clustering.dist2(z[i], centroids[c]); if d < bestD { bestD = d; bestC = c } }
                if assign[i] != bestC { assign[i] = bestC; changed = true }
                inertia += bestD
            }
            if !changed { break }
            var sums = [[Double]](repeating: [Double](repeating: 0, count: dims), count: k)
            var counts = [Int](repeating: 0, count: k)
            for i in 0..<n { counts[assign[i]] += 1; for d in 0..<dims { sums[assign[i]][d] += z[i][d] } }
            for c in 0..<k {
                if counts[c] > 0 { centroids[c] = sums[c].map { $0 / Double(counts[c]) } }
                else {
                    // Re-seed an empty cluster at the point farthest from its centroid.
                    var far = 0, farD = -1.0
                    for i in 0..<n { let d = Clustering.dist2(z[i], centroids[assign[i]]); if d > farD { farD = d; far = i } }
                    centroids[c] = z[far]
                }
            }
        }
        return Run(assignments: assign, centroids: centroids, inertia: inertia)
    }
}

/// Density-based clustering (DBSCAN). Finds arbitrarily shaped clusters and labels sparse points as noise (−1).
public enum DBSCAN {
    /// - Parameters:
    ///   - eps: neighbourhood radius in standardised units; nil estimates it from the knee of the k-distance curve.
    ///   - minPoints: minimum neighbours (including the point itself) for a core point.
    public static func cluster(points: [[Double]], eps: Double? = nil, minPoints: Int = 4, standardize: Bool = true) throws -> ClusterResult {
        guard points.count >= 2, let dims = points.first?.count, dims > 0 else { throw ClusteringError.noData }
        guard points.allSatisfy({ $0.count == dims }) else { throw ClusteringError.raggedInput }
        let (z, means, sds) = Clustering.standardise(points, enabled: standardize)
        let n = z.count
        let radius = eps ?? estimateEps(z, minPoints: minPoints)
        let r2 = radius * radius
        func neighbours(_ i: Int) -> [Int] { (0..<n).filter { Clustering.dist2(z[i], z[$0]) <= r2 } }
        var labels = [Int](repeating: -2, count: n) // -2 unvisited, -1 noise
        var cluster = 0
        for i in 0..<n where labels[i] == -2 {
            let nb = neighbours(i)
            if nb.count < minPoints { labels[i] = -1; continue }
            labels[i] = cluster
            var queue = nb
            var head = 0
            while head < queue.count {
                let j = queue[head]; head += 1
                if labels[j] == -1 { labels[j] = cluster }
                if labels[j] != -2 { continue }
                labels[j] = cluster
                let nb2 = neighbours(j)
                if nb2.count >= minPoints { queue.append(contentsOf: nb2) }
            }
            cluster += 1
        }
        var sums = [[Double]](repeating: [Double](repeating: 0, count: dims), count: cluster)
        var sizes = [Int](repeating: 0, count: cluster)
        for i in 0..<n where labels[i] >= 0 { sizes[labels[i]] += 1; for d in 0..<dims { sums[labels[i]][d] += z[i][d] } }
        let zc = (0..<cluster).map { c in sums[c].map { $0 / Double(max(1, sizes[c])) } }
        var inertia = 0.0
        for i in 0..<n where labels[i] >= 0 { inertia += Clustering.dist2(z[i], zc[labels[i]]) }
        let kept = (0..<n).filter { labels[$0] >= 0 }
        let sil = cluster >= 2 ? Clustering.silhouette(kept.map { z[$0] }, assignments: kept.map { labels[$0] }, k: cluster, seed: 42) : 0
        return ClusterResult(assignments: labels, centroids: zc.map { c in (0..<dims).map { c[$0] * sds[$0] + means[$0] } },
                             k: cluster, silhouette: sil, inertia: inertia, sizes: sizes)
    }

    /// Knee of the sorted k-nearest-neighbour distance curve.
    static func estimateEps(_ z: [[Double]], minPoints: Int) -> Double {
        let n = z.count
        let k = max(1, min(minPoints - 1, n - 1))
        var kd: [Double] = []
        for i in 0..<n {
            var d = (0..<n).filter { $0 != i }.map { Clustering.dist2(z[i], z[$0]) }
            d.sort()
            kd.append(sqrt(d[k - 1]))
        }
        kd.sort()
        guard let first = kd.first, let last = kd.last, last > first, n > 2 else { return max(kd.last ?? 0.5, 1e-6) }
        var bestI = n - 1, bestGap = -1.0
        for i in 0..<n {
            let onLine = first + (last - first) * Double(i) / Double(n - 1)
            let gap = onLine - kd[i]
            if gap > bestGap { bestGap = gap; bestI = i }
        }
        return max(kd[bestI], 1e-9)
    }
}

/// Shared clustering utilities and table-level convenience.
public enum Clustering {
    public enum Method: Sendable { case kMeans(k: Int?), dbscan(eps: Double?, minPoints: Int) }

    /// Clusters the rows of a table on the named numeric columns. Rows with a missing value in any of the
    /// columns get nil. The result can be stored in `AnalyticsOverlays.clusters` after mapping nil to −1.
    public static func cluster(table: DataTable, columns: [String], method: Method = .kMeans(k: nil), seed: UInt64 = 42)
        throws -> (assignments: [Int?], result: ClusterResult) {
        let idx = columns.compactMap { table.columnIndex($0) }
        guard !idx.isEmpty, idx.count == columns.count else { throw ClusteringError.noData }
        var rows: [Int] = [], pts: [[Double]] = []
        for r in 0..<table.rowCount {
            let vals = idx.compactMap { table[r, $0].asDouble }.filter(\.isFinite)
            if vals.count == idx.count { rows.append(r); pts.append(vals) }
        }
        let result: ClusterResult
        switch method {
        case .kMeans(let k): result = try KMeans.cluster(points: pts, k: k, seed: seed)
        case .dbscan(let eps, let minPoints): result = try DBSCAN.cluster(points: pts, eps: eps, minPoints: minPoints)
        }
        var out = [Int?](repeating: nil, count: table.rowCount)
        for (i, r) in rows.enumerated() { out[r] = result.assignments[i] }
        return (out, result)
    }

    static func standardise(_ pts: [[Double]], enabled: Bool) -> ([[Double]], [Double], [Double]) {
        let dims = pts[0].count
        guard enabled else { return (pts, [Double](repeating: 0, count: dims), [Double](repeating: 1, count: dims)) }
        var means = [Double](repeating: 0, count: dims), sds = [Double](repeating: 1, count: dims)
        for d in 0..<dims {
            let col = pts.map { $0[d] }
            means[d] = Stats.mean(col)
            let sd = Stats.stdDev(col, sample: false)
            sds[d] = sd > 0 && sd.isFinite ? sd : 1
        }
        return (pts.map { p in (0..<dims).map { (p[$0] - means[$0]) / sds[$0] } }, means, sds)
    }

    static func dist2(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in 0..<a.count { let d = a[i] - b[i]; s += d * d }
        return s
    }

    /// Mean silhouette coefficient. Uses a deterministic sample of at most `sampleLimit` points for large inputs.
    public static func silhouette(_ pts: [[Double]], assignments: [Int], k: Int, seed: UInt64 = 42, sampleLimit: Int = 600) -> Double {
        let n = pts.count
        guard k >= 2, n > k else { return 0 }
        var idx = Array(0..<n)
        if n > sampleLimit {
            var rng = SeededGenerator(seed: seed)
            idx.shuffle(using: &rng)
            idx = Array(idx.prefix(sampleLimit))
        }
        var counts = [Int](repeating: 0, count: k)
        for i in idx { counts[assignments[i]] += 1 }
        var total = 0.0, used = 0
        for i in idx {
            var sums = [Double](repeating: 0, count: k)
            for j in idx where j != i { sums[assignments[j]] += sqrt(dist2(pts[i], pts[j])) }
            let own = assignments[i]
            guard counts[own] > 1 else { used += 1; continue } // singleton: silhouette 0
            let a = sums[own] / Double(counts[own] - 1)
            var b = Double.infinity
            for c in 0..<k where c != own && counts[c] > 0 { b = min(b, sums[c] / Double(counts[c])) }
            guard b.isFinite else { continue }
            let m = max(a, b)
            total += m > 0 ? (b - a) / m : 0
            used += 1
        }
        return used > 0 ? total / Double(used) : 0
    }
}
