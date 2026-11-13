import Foundation
import CoreServices

/// Watches a project folder (FSEvents) and reports external edits so the app can reload instantly.
/// Changes are debounced, and a content signature (path, size, modification time) filters out events that
/// didn't actually change a project file — including the app's own saves once `markSynced()` is called.
public final class PBIPWatcher {
    public let folder: URL
    private let debounce: TimeInterval
    private let onChange: ([URL]) -> Void
    private let callbackQueue: DispatchQueue
    private let queue = DispatchQueue(label: "facet.pbip.watcher")
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var signature: [String: String] = [:]

    init(folder: URL, debounce: TimeInterval, callbackQueue: DispatchQueue, onChange: @escaping ([URL]) -> Void) {
        self.folder = folder.standardizedFileURL
        self.debounce = debounce
        self.callbackQueue = callbackQueue
        self.onChange = onChange
    }

    deinit { stop() }

    /// Files that matter for reload: project text files, not caches or Git internals.
    static func isRelevant(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/")
        if parts.contains(".git") || parts.contains(".pbi") || parts.last == ".DS_Store" { return false }
        guard let ext = parts.last?.split(separator: ".").last?.lowercased() else { return false }
        return ["json", "tmdl", "pbip", "pbir", "pbism", "platform", "bim", "dax", "m"].contains(ext) || parts.last == ".platform"
    }

    static func snapshot(_ folder: URL) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: folder.path) else { return out }
        for case let rel as String in walker where isRelevant(rel) {
            guard let attrs = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(rel).path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out[rel] = "\(size):\(modified)"
        }
        return out
    }

    func start() throws {
        signature = PBIPWatcher.snapshot(folder)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<PBIPWatcher>.fromOpaque(info).takeUnretainedValue().eventsArrived()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [folder.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
            throw InteropError.io("Couldn't watch “\(folder.path)” for changes.")
        }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            throw InteropError.io("Couldn't start watching “\(folder.path)”.")
        }
        stream = s
    }

    private func eventsArrived() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func evaluate() {
        let now = PBIPWatcher.snapshot(folder)
        let changed = Set(now.keys).union(signature.keys).filter { now[$0] != signature[$0] }.sorted()
        signature = now
        guard !changed.isEmpty else { return }
        let urls = changed.map { folder.appendingPathComponent($0) }
        callbackQueue.async { [onChange] in onChange(urls) }
    }

    /// Call after the app itself writes the project so its own save isn't reported as an external change.
    public func markSynced() {
        queue.sync {
            pending?.cancel()
            signature = PBIPWatcher.snapshot(folder)
        }
    }

    /// Stops watching. Safe to call more than once.
    public func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }
}

public extension PBIPProject {
    /// Starts watching a project folder for external edits (VS Code, Git checkout, an agent…).
    /// `onChange` receives the changed files on `callbackQueue` after `debounce` seconds of quiet. Keep the returned watcher alive.
    static func watch(folder: URL, debounce: TimeInterval = 0.3, callbackQueue: DispatchQueue = .main,
                      onChange: @escaping ([URL]) -> Void) throws -> PBIPWatcher {
        let w = PBIPWatcher(folder: folder, debounce: debounce, callbackQueue: callbackQueue, onChange: onChange)
        try w.start()
        return w
    }

    /// How Visual Studio Code would be launched for `folder`: the `code` CLI if found, otherwise the app bundle via `open`.
    static func vsCodeLaunchPlan(folder: URL, environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
                                 fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) || FileManager.default.fileExists(atPath: $0) })
        -> (executable: String, arguments: [String])? {
        var candidates = (environmentPath ?? "").split(separator: ":").map { "\($0)/code" }
        candidates += ["/usr/local/bin/code", "/opt/homebrew/bin/code",
                       "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
                       NSHomeDirectory() + "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"]
        if let cli = candidates.first(where: fileExists) { return (cli, [folder.path]) }
        let apps = ["/Applications/Visual Studio Code.app", NSHomeDirectory() + "/Applications/Visual Studio Code.app"]
        if apps.contains(where: fileExists) { return ("/usr/bin/open", ["-a", "Visual Studio Code", folder.path]) }
        return nil
    }

    /// Opens the project folder in Visual Studio Code. Throws a clear error when VS Code isn't installed.
    static func openInVSCode(folder: URL) throws {
        func run(_ exe: String, _ args: [String]) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        if let plan = vsCodeLaunchPlan(folder: folder), run(plan.executable, plan.arguments) { return }
        // Last resort: let Launch Services look for the app anywhere.
        if run("/usr/bin/open", ["-a", "Visual Studio Code", folder.path]) { return }
        throw InteropError.unsupported("Visual Studio Code isn't installed. Install it from code.visualstudio.com (and optionally run “Shell Command: Install 'code' command in PATH”), then try again.")
    }
}
