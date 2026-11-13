import Foundation
import CoreLocation
import Combine

/// Disk cache of geocoding results (hits and confirmed misses), keyed by normalised query text.
/// Stored as JSON: `{ "paris, france": {"lat": 48.85, "lon": 2.35}, "atlantis": {"miss": true} }`.
final class CmpGeocodeCache {
    enum Entry: Equatable {
        case hit(lat: Double, lon: Double)
        case miss
    }
    let url: URL
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private var dirty = false

    /// Default location: `~/Library/Application Support/Facet/GeocodeCache.json`.
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Facet", isDirectory: true).appendingPathComponent("GeocodeCache.json")
    }

    init(url: URL = CmpGeocodeCache.defaultURL) {
        self.url = url
        load()
    }

    static func key(_ query: String) -> String { CmpGeo.normalise(query) }

    func lookup(_ query: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[CmpGeocodeCache.key(query)]
    }

    func store(_ query: String, _ entry: Entry) {
        lock.lock()
        entries[CmpGeocodeCache.key(query)] = entry
        dirty = true
        lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else { return }
        for (k, v) in obj {
            if let lat = (v["lat"] as? NSNumber)?.doubleValue, let lon = (v["lon"] as? NSNumber)?.doubleValue {
                entries[k] = .hit(lat: lat, lon: lon)
            } else if v["miss"] as? Bool == true {
                entries[k] = .miss
            }
        }
    }

    /// Writes the cache atomically when it has changed. Returns false when the write failed.
    @discardableResult func save() -> Bool {
        lock.lock()
        guard dirty else { lock.unlock(); return true }
        var obj: [String: [String: Any]] = [:]
        for (k, e) in entries {
            switch e {
            case .hit(let lat, let lon): obj[k] = ["lat": lat, "lon": lon]
            case .miss: obj[k] = ["miss": true]
            }
        }
        dirty = false
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            lock.lock(); dirty = true; lock.unlock()
            return false
        }
    }
}

/// Resolves location text to coordinates with `CLGeocoder`: one request at a time, throttled, with
/// results cached on disk so each distinct location is only ever looked up once.
final class CmpGeocoder: ObservableObject {
    static let shared = CmpGeocoder(cache: CmpGeocodeCache())

    /// Resolved coordinates by normalised query (hits only).
    @Published private(set) var coordinates: [String: CLLocationCoordinate2D] = [:]
    /// Queries requested in the current batch and how many are finished.
    @Published private(set) var total = 0
    @Published private(set) var done = 0
    /// Human-readable description of the last service failure (network / rate limit), if any.
    @Published private(set) var lastError: String?

    let cache: CmpGeocodeCache
    /// Minimum spacing between requests. Apple rate-limits geocoding; ~1 request/second is safe.
    var minimumInterval: TimeInterval = 1.1
    private let geocoder = CLGeocoder()
    private var queue: [String] = []
    private var queued = Set<String>()
    private var running = false
    private var retries: [String: Int] = [:]
    private var misses = Set<String>()

    init(cache: CmpGeocodeCache) { self.cache = cache }

    var isWorking: Bool { done < total }

    func coordinate(for query: String) -> CLLocationCoordinate2D? { coordinates[CmpGeocodeCache.key(query)] }
    func isKnownMiss(_ query: String) -> Bool { misses.contains(CmpGeocodeCache.key(query)) }

    /// Requests coordinates for the given location strings. Cached answers are published immediately;
    /// the rest are queued. Safe to call repeatedly with the same values. Main thread only.
    func resolve(_ queries: [String]) {
        var newHits: [String: CLLocationCoordinate2D] = [:]
        for q in queries {
            let key = CmpGeocodeCache.key(q)
            if key.isEmpty || coordinates[key] != nil || misses.contains(key) || queued.contains(key) { continue }
            switch cache.lookup(key) {
            case .hit(let lat, let lon): newHits[key] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            case .miss: misses.insert(key)
            case nil:
                queued.insert(key); queue.append(key)
                total += 1
            }
        }
        if !newHits.isEmpty { coordinates.merge(newHits) { a, _ in a } }
        pump()
    }

    private func pump() {
        guard !running else { return }
        guard let key = queue.first else {
            if total != 0 { total = 0; done = 0 }
            cache.save()
            return
        }
        running = true
        geocoder.geocodeAddressString(key) { [weak self] placemarks, error in
            DispatchQueue.main.async { self?.finish(key, placemarks: placemarks, error: error) }
        }
    }

    private func finish(_ key: String, placemarks: [CLPlacemark]?, error: Error?) {
        var delay = minimumInterval
        var completed = true
        if let c = placemarks?.first?.location?.coordinate {
            coordinates[key] = c
            cache.store(key, .hit(lat: c.latitude, lon: c.longitude))
            lastError = nil
        } else if let e = error as? CLError, e.code == .geocodeFoundNoResult || e.code == .geocodeFoundPartialResult {
            misses.insert(key)
            cache.store(key, .miss)
        } else {
            // Network failure or rate limiting: do not cache; back off and retry a couple of times.
            let n = (retries[key] ?? 0) + 1
            retries[key] = n
            lastError = "Location lookup is unavailable (\(error?.localizedDescription ?? "unknown error")). Check the network connection; lookups resume automatically."
            if n <= 2 { completed = false; delay = 20 } else { misses.insert(key) }
        }
        if completed {
            queue.removeFirst(); queued.remove(key)
            done += 1
            if done % 10 == 0 { cache.save() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.running = false
            self?.pump()
        }
    }
}
