import Foundation
import FacetCore

/// Settings ▸ Diagnostics ▸ Enable tracing: a log of what the engines did and how long it took, one JSON
/// object per line in the Traces folder (a file per day). Only counts, durations and object names are
/// written: never data values, DAX or M text, error messages (which can quote values) or credentials.
final class TraceLog: @unchecked Sendable {
    static let shared = TraceLog()

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(AppIdentity.name).appendingPathComponent("Traces")
    }

    /// What a trace line may hold.
    enum Field: Equatable {
        case count(Int)
        case milliseconds(Double)
        /// The name of a model object, query or visual type.
        case name(String)
        case flag(Bool)

        var json: Any {
            switch self {
            case .count(let n): return n
            case .milliseconds(let ms): return (ms * 10).rounded() / 10
            case .name(let s): return s
            case .flag(let b): return b
            }
        }
    }

    private let lock = NSLock()
    private var _directory: URL
    private var _isEnabled: () -> Bool
    private let queue = DispatchQueue(label: "TraceLog", qos: .utility)

    init(directory: URL = TraceLog.defaultDirectory, isEnabled: @escaping () -> Bool = { AppSettings.bool(.tracing) }) {
        _directory = directory
        _isEnabled = isEnabled
    }

    var directory: URL {
        get { lock.lock(); defer { lock.unlock() }; return _directory }
        set { lock.lock(); _directory = newValue; lock.unlock() }
    }
    var isEnabled: Bool { lock.lock(); let f = _isEnabled; lock.unlock(); return f() }
    func setEnabled(_ check: @escaping () -> Bool) { lock.lock(); _isEnabled = check; lock.unlock() }

    /// Today's trace file.
    func fileURL(on date: Date = Date()) -> URL {
        let day = DateParsing.string(date, format: "yyyy-MM-dd")
        return directory.appendingPathComponent("trace-\(day).jsonl")
    }

    /// Appends one event, when tracing is on. Writing happens off the caller's thread.
    func record(_ event: String, _ fields: [String: Field]) {
        guard isEnabled else { return }
        let now = Date()
        var object: [String: Any] = ["time": ISO8601DateFormatter.string(from: now, timeZone: TimeZone(identifier: "UTC") ?? .current,
                                                                           formatOptions: [.withInternetDateTime, .withFractionalSeconds]),
                                     "event": event]
        for (k, v) in fields where k != "time" && k != "event" { object[k] = v.json }
        let url = fileURL(on: now)
        queue.async {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        }
    }

    /// Waits until everything recorded so far is written.
    func flush() { queue.sync {} }

    /// Milliseconds since `start` (from `DispatchTime.now()`).
    static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }
}
