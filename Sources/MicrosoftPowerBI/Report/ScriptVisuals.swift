import Foundation
import FacetCore
import FacetQuery

/// Python and R visuals: the script runs with the visual's fields as a data frame named
/// `dataset`, through the Python.Execute / R.Execute steps of the query engine (the same
/// interpreters, paths and "Allow Python and R scripts to run" setting as Get Data), and the plot
/// it draws is shown in the visual.
enum ScriptLanguage: String, Sendable {
    case python = "Python", r = "R"

    init?(_ type: VisualType) {
        switch type {
        case .pythonVisual: self = .python
        case .rVisual: self = .r
        default: return nil
        }
    }

    var executeFunction: String { self == .python ? "Python.Execute" : "R.Execute" }
}

/// One run of a script visual: the script, its data and the plot's size in points.
struct ScriptJob: Sendable {
    var language: ScriptLanguage
    var script: String
    var dataset: DataTable
    var width: Int
    var height: Int

    /// Same inputs, same key: a run is reused until the script, the data or the size changes.
    var key: Int {
        var h = Hasher()
        h.combine(language.rawValue); h.combine(script); h.combine(width); h.combine(height)
        h.combine(dataset.columnNames)
        for c in dataset.columns { for v in c.values { h.combine(v.asString); h.combine(v.isNull) } }
        return h.finalize()
    }
}

/// A script visual that could not draw, with a message saying what to do.
struct ScriptVisualError: Error, LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Draws a script visual's plot: returns the PNG the script drew, or throws `ScriptVisualError`.
protocol ScriptVisualRunner: Sendable {
    func render(_ job: ScriptJob) throws -> Data
}

/// Runs scripts with the query engine's Python.Execute / R.Execute (FacetQuery's ScriptRunner).
struct LiveScriptRunner: ScriptVisualRunner {
    /// The engine environment: allowed scripts and the interpreter paths from Settings.
    var environment: @Sendable () -> QueryEnvironment

    func render(_ job: ScriptJob) throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("facet-plot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        var env = environment()
        // CRAN's installer puts Rscript inside the framework, which is not on a GUI app's PATH.
        if job.language == .r { env.toolSearchPaths.append("/Library/Frameworks/R.framework/Resources/bin") }
        let vars: [String: MValue] = [
            "facetScript": .text(ScriptVisuals.composed(job, output: output)),
            "facetDataset": .table(MTable(ScriptVisuals.dataset(job.dataset))),
        ]
        do {
            _ = try MInterpreter(environment: env).evaluate("\(job.language.executeFunction)(facetScript, [dataset = facetDataset])",
                                                           env: MEnv(parent: nil, vars: vars))
        } catch let error as MError {
            throw ScriptVisualError(ScriptVisuals.explain(error.message, language: job.language))
        }
        guard let png = try? Data(contentsOf: output), ScriptVisuals.isPNG(png) else {
            throw ScriptVisualError(ScriptVisuals.nothingDrawn(job.language))
        }
        return png
    }
}

enum ScriptVisuals {
    static func isScript(_ type: VisualType) -> Bool { ScriptLanguage(type) != nil }

    /// The data frame the script gets: the visual's rows, named by the fields' captions (made
    /// unique, as a data frame needs).
    static func dataset(_ table: DataTable) -> DataTable {
        var out = table
        var taken = Set<String>()
        for i in out.columns.indices {
            let base = out.columns[i].name
            var name = base, n = 2
            while taken.contains(name) { name = "\(base) \(n)"; n += 1 }
            taken.insert(name)
            out.columns[i].name = name
        }
        return out
    }

    /// The comment Power BI shows above the script: how `dataset` is made.
    static func preamble(_ language: ScriptLanguage, columns: [String]) -> String {
        let list = columns.isEmpty ? "…" : columns.joined(separator: ", ")
        switch language {
        case .python: return "# dataset = pandas.DataFrame(\(list)), duplicate rows removed"
        case .r: return "# dataset <- data.frame(\(list)), duplicate rows removed"
        }
    }

    /// The script with what makes it draw off screen, at the visual's size, into `output`:
    /// Python uses matplotlib's Agg backend and saves the current figure; R draws on a png device.
    static func composed(_ job: ScriptJob, output: URL) -> String {
        let path = literal(output.path)
        let w = max(job.width, 1), h = max(job.height, 1)
        switch job.language {
        case .python:
            return """
            try:
                import matplotlib as _facet_mpl
                _facet_mpl.use("Agg")
                _facet_mpl.rcParams["figure.figsize"] = (\(w) / 72, \(h) / 72)
            except ImportError:
                pass
            \(job.script)
            try:
                import matplotlib.pyplot as _facet_plt
                if _facet_plt.get_fignums():
                    _facet_plt.gcf().savefig(\(path), format="png", dpi=144)
            except ImportError:
                pass

            """
        case .r:
            return """
            png(filename = \(path), width = \(w * 2), height = \(h * 2), res = 144)
            \(job.script)
            invisible(dev.off())

            """
        }
    }

    /// A double-quoted string literal both Python and R read back as `s`.
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func isPNG(_ data: Data) -> Bool { data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) }

    static func nothingDrawn(_ language: ScriptLanguage) -> String {
        switch language {
        case .python: return "The script ran but drew nothing. Draw a plot with matplotlib, for example dataset.plot(), and it shows here."
        case .r: return "The script ran but drew nothing. Draw a plot, for example plot(dataset), and it shows here. A ggplot needs print()."
        }
    }

    static func turnedOff(_ language: ScriptLanguage) -> String {
        "\(language.rawValue) visuals are turned off. Turn on “Allow Python and R scripts to run” in Settings › Scripting to draw this visual on this Mac."
    }

    /// What the engine's error means for the author: a missing interpreter or package named as
    /// such, with how to install it; otherwise the script's own error.
    static func explain(_ message: String, language: ScriptLanguage) -> String {
        let name = language.rawValue
        if message.contains("scripts are turned off") { return turnedOff(language) }
        if message.contains("No \(name) installation was found") {
            return "\(name) isn't installed, or \(AppIdentity.name) can't find it. Install \(name), or set the path to it in Settings › Scripting."
        }
        if message.contains("wasn't found") || message.contains("couldn't be started") {
            return message.replacingOccurrences(of: "in Options", with: "in Settings › Scripting")
        }
        if let package = missingPackage(in: message, language: language) {
            switch language {
            case .python:
                return "The Python package “\(package.module)” isn't installed. Install it with: python3 -m pip install \(package.install)"
            case .r:
                return "The R package “\(package.module)” isn't installed. Install it in R with: install.packages(\"\(package.install)\")"
            }
        }
        let prefix = "The \(name) script failed: "
        let detail = message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message
        // A traceback ends with the error itself: keep its last lines.
        let lines = detail.split(separator: "\n", omittingEmptySubsequences: true).suffix(6)
        return "The \(name) script failed:\n" + lines.joined(separator: "\n")
    }

    /// The package a script needed and didn't find: Python's "No module named 'x'", the
    /// wrapper's own pandas check, or R's "there is no package called ‘x’".
    static func missingPackage(in message: String, language: ScriptLanguage) -> (module: String, install: String)? {
        switch language {
        case .python:
            if message.contains("The pandas package is required") { return ("pandas", "pandas") }
            guard let r = message.range(of: "No module named ") else { return nil }
            let rest = message[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            let module = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
            guard let top = module.split(separator: ".").first.map(String.init), !top.isEmpty else { return nil }
            let install = ["sklearn": "scikit-learn", "cv2": "opencv-python", "PIL": "pillow", "yaml": "pyyaml", "bs4": "beautifulsoup4"][top] ?? top
            return (top, install)
        case .r:
            guard let r = message.range(of: "there is no package called ") else { return nil }
            let rest = message[r.upperBound...].drop { "‘'\"".contains($0) }
            let package = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" })
            return package.isEmpty ? nil : (package, package)
        }
    }
}

/// Runs script visuals off the main thread, one at a time, and keeps each visual's last plot.
@MainActor
final class ScriptVisualRuntime: ObservableObject {
    enum State: Equatable {
        case running
        case drawn(Data)
        case failed(String)
    }

    struct Entry: Equatable {
        var key: Int
        /// The Run count the entry was made for (see `runs`).
        var run = 0
        var state: State
        /// The last plot drawn, still shown while a new run is under way or after it failed.
        var lastImage: Data?
        var milliseconds: Double = 0
    }

    @Published private(set) var entries: [UUID: Entry] = [:]
    /// Bumped by "Run" so a visual whose inputs did not change runs again.
    @Published private(set) var runs: [UUID: Int] = [:]
    let runner: ScriptVisualRunner
    private var generations: [UUID: Int] = [:]
    private let queue = DispatchQueue(label: "facet.script-visuals", qos: .userInitiated)

    init(runner: ScriptVisualRunner) { self.runner = runner }

    private static var all: [ObjectIdentifier: (store: WeakStore, runtime: ScriptVisualRuntime)] = [:]
    private final class WeakStore { weak var store: DocumentStore?; init(_ s: DocumentStore) { store = s } }

    /// The store's runtime, running scripts with the app's query environment.
    static func of(_ store: DocumentStore) -> ScriptVisualRuntime {
        let key = ObjectIdentifier(store)
        if let existing = all[key], existing.store.store === store { return existing.runtime }
        for (k, v) in all where v.store.store == nil { all[k] = nil }
        let folder = store.fileURL?.deletingLastPathComponent()
        let runtime = ScriptVisualRuntime(runner: LiveScriptRunner { QueryEnvironment.app(baseDirectory: folder) })
        all[key] = (WeakStore(store), runtime)
        return runtime
    }

    func entry(_ id: UUID) -> Entry? { entries[id] }

    /// Runs `job` for the visual unless its last run had the same inputs and the same Run count.
    func request(_ job: ScriptJob, for id: UUID) {
        let key = job.key, run = runs[id] ?? 0
        if let e = entries[id], e.key == key, e.run == run { return }
        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation
        let last = entries[id]?.lastImage
        entries[id] = Entry(key: key, run: run, state: .running, lastImage: last)
        let runner = self.runner
        queue.async { [weak self] in
            let start = CFAbsoluteTimeGetCurrent()
            let result: Result<Data, Error> = Result { try runner.render(job) }
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            DispatchQueue.main.async {
                guard let self, self.generations[id] == generation else { return }
                switch result {
                case .success(let png):
                    self.entries[id] = Entry(key: key, run: run, state: .drawn(png), lastImage: png, milliseconds: ms)
                case .failure(let error):
                    let message = (error as? ScriptVisualError)?.message ?? error.localizedDescription
                    self.entries[id] = Entry(key: key, run: run, state: .failed(message), lastImage: last, milliseconds: ms)
                }
            }
        }
    }

    /// Runs the visual's script again with the same inputs (the editor's Run button).
    func runAgain(_ id: UUID) { runs[id, default: 0] += 1 }
}
