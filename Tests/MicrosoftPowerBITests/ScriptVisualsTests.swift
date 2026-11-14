import XCTest
import ImageIO
import FacetCore
import FacetQuery
@testable import MicrosoftPowerBI

/// Python and R visuals: the script runs with the visual's fields as `dataset` through the query
/// engine's Python.Execute / R.Execute, draws off screen at the visual's size, and the plot shows.
@MainActor
final class ScriptVisualsTests: XCTestCase {
    private func job(_ script: String, _ language: ScriptLanguage = .python, width: Int = 300, height: Int = 200) -> ScriptJob {
        let data = ReportFixture.engine().visualData(spec: ReportFixture.chart(), request: VisualRequest())
        return ScriptJob(language: language, script: script, dataset: VisualExport.captioned(data), width: width, height: height)
    }

    // MARK: - Composition

    func testPythonDrawsWithAggAtTheVisualsSize() {
        let out = URL(fileURLWithPath: "/tmp/plot.png")
        let text = ScriptVisuals.composed(job("import matplotlib.pyplot as plt\nplt.plot([1, 2])"), output: out)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.prefix(4), ["try:", "    import matplotlib as _facet_mpl", "    _facet_mpl.use(\"Agg\")",
                                         "    _facet_mpl.rcParams[\"figure.figsize\"] = (300 / 72, 200 / 72)"])
        XCTAssertTrue(lines.contains("import matplotlib.pyplot as plt"))
        XCTAssertTrue(lines.contains("plt.plot([1, 2])"))
        XCTAssertTrue(lines.contains("        _facet_plt.gcf().savefig(\"/tmp/plot.png\", format=\"png\", dpi=144)"))
        // The user's script comes before the save, the backend before the script.
        let script = lines.firstIndex(of: "plt.plot([1, 2])") ?? 0
        XCTAssertLessThan(lines.firstIndex(of: "    _facet_mpl.use(\"Agg\")") ?? .max, script)
        XCTAssertGreaterThan(lines.firstIndex { $0.contains("savefig") } ?? 0, script)
    }

    func testRDrawsOnAPngDevice() {
        let text = ScriptVisuals.composed(job("plot(dataset)", .r, width: 300, height: 200), output: URL(fileURLWithPath: "/tmp/plot.png"))
        // 300 × 200 points at 144 dpi is 600 × 400 pixels.
        XCTAssertEqual(text, "png(filename = \"/tmp/plot.png\", width = 600, height = 400, res = 144)\nplot(dataset)\ninvisible(dev.off())\n")
        XCTAssertEqual(ScriptVisuals.literal(#"/a\b"c"#), #""/a\\b\"c""#)
    }

    func testDatasetColumnsAreTheCaptionsMadeUnique() {
        let t = DataTable(name: "T", columnNames: ["Total", "Total", "Region"], rows: [[.int(1), .int(2), .string("N")]],
                          types: [.integer, .integer, .text])
        XCTAssertEqual(ScriptVisuals.dataset(t).columnNames, ["Total", "Total 2", "Region"])
        XCTAssertEqual(job("x").dataset.columnNames, ["Region", "Sum of Amount"])
        XCTAssertEqual(ScriptVisuals.preamble(.python, columns: ["Region", "Sum of Amount"]),
                       "# dataset = pandas.DataFrame(Region, Sum of Amount), duplicate rows removed")
    }

    // MARK: - Messages

    func testMissingInterpretersAndPackagesAreNamed() {
        XCTAssertEqual(ScriptVisuals.explain("No Python installation was found. Install Python or set its path in Options.", language: .python),
                       "Python isn't installed, or \(AppIdentity.name) can't find it. Install Python, or set the path to it in Settings › Scripting.")
        XCTAssertEqual(ScriptVisuals.explain("The Python interpreter '/x/python3' wasn't found. Check the Python scripting path in Options.", language: .python),
                       "The Python interpreter '/x/python3' wasn't found. Check the Python scripting path in Settings › Scripting.")
        let traceback = "The Python script failed: Traceback (most recent call last):\n  File \"script\", line 1, in <module>\nModuleNotFoundError: No module named 'seaborn'"
        XCTAssertEqual(ScriptVisuals.explain(traceback, language: .python),
                       "The Python package “seaborn” isn't installed. Install it with: python3 -m pip install seaborn")
        XCTAssertEqual(ScriptVisuals.explain("ModuleNotFoundError: No module named 'sklearn.linear_model'", language: .python),
                       "The Python package “sklearn” isn't installed. Install it with: python3 -m pip install scikit-learn")
        XCTAssertEqual(ScriptVisuals.explain("The Python script failed: The pandas package is required to run Python scripts. Install it with: python3 -m pip install pandas", language: .python),
                       "The Python package “pandas” isn't installed. Install it with: python3 -m pip install pandas")
        XCTAssertEqual(ScriptVisuals.explain("The R script failed: Error in library(ggplot2) : there is no package called ‘ggplot2’", language: .r),
                       "The R package “ggplot2” isn't installed. Install it in R with: install.packages(\"ggplot2\")")
        XCTAssertEqual(ScriptVisuals.explain("Error in library(zoo) : there is no package called 'zoo'", language: .r),
                       "The R package “zoo” isn't installed. Install it in R with: install.packages(\"zoo\")")
        XCTAssertEqual(ScriptVisuals.explain("R scripts are turned off. Allow script execution for this file to run the step.", language: .r),
                       ScriptVisuals.turnedOff(.r))
        XCTAssertEqual(ScriptVisuals.explain("The Python script failed: a\nb\nNameError: name 'x' is not defined", language: .python),
                       "The Python script failed:\na\nb\nNameError: name 'x' is not defined")
    }

    func testScriptsOnlyRunWhenAllowed() {
        var env = QueryEnvironment()
        env.allowScripts = false
        let environment = env
        let runner = LiveScriptRunner { environment }
        XCTAssertThrowsError(try runner.render(job("x = 1"))) { error in
            XCTAssertEqual(error as? ScriptVisualError, ScriptVisualError(ScriptVisuals.turnedOff(.python)))
        }
    }

    // MARK: - Runtime

    func testRuntimeRunsOncePerInputsAgainOnRunAndKeepsTheLastPlot() async throws {
        let stub = StubRunner()
        let runtime = ScriptVisualRuntime(runner: stub)
        let id = UUID()
        let first = job("draw()")
        runtime.request(first, for: id)
        XCTAssertEqual(runtime.entry(id)?.state, .running)
        try await settle(runtime, id)
        XCTAssertEqual(runtime.entry(id)?.state, .drawn(StubRunner.png))
        XCTAssertEqual(stub.calls, 1)

        runtime.request(first, for: id)              // same inputs: the plot is reused
        XCTAssertEqual(stub.calls, 1)
        runtime.runAgain(id)                         // Run: same inputs, run again
        runtime.request(first, for: id)
        try await settle(runtime, id)
        XCTAssertEqual(stub.calls, 2)
        runtime.request(job("draw()", width: 400), for: id)   // a new size draws again
        try await settle(runtime, id)
        XCTAssertEqual(stub.calls, 3)

        runtime.request(job("fail"), for: id)
        try await settle(runtime, id)
        XCTAssertEqual(runtime.entry(id)?.state, .failed("Stub failure"))
        XCTAssertEqual(runtime.entry(id)?.lastImage, StubRunner.png)
    }

    func testOnlyTheLatestRunOfAVisualIsKept() async throws {
        let stub = StubRunner()
        let runtime = ScriptVisualRuntime(runner: stub)
        let id = UUID()
        runtime.request(job("slow"), for: id)
        let latest = job("draw()")
        runtime.request(latest, for: id)
        for _ in 0..<200 where stub.calls < 2 || runtime.entry(id)?.state == .running {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(runtime.entry(id)?.key, latest.key)
        XCTAssertEqual(runtime.entry(id)?.state, .drawn(StubRunner.png))
    }

    func testTheCanvasDrawsScriptVisualsItself() {
        let store = ReportFixture.store()
        var python = VisualSpec(type: .pythonVisual, frame: Frame(x: 0, y: 0, width: 300, height: 200))
        python.setFields(.values, [ReportFixture.region])
        let context = store.context(for: python)
        XCTAssertNotNil(context.extensionView?(python, VisualData(), context))
        XCTAssertNil(ScriptVisuals.view(ReportFixture.chart(), VisualData(), context, store))
        XCTAssertTrue(ScriptVisuals.isScript(.rVisual))
        XCTAssertFalse(ScriptVisuals.isScript(.table))
    }

    // MARK: - A real run (needs python3 with pandas and matplotlib)

    func testPythonDrawsThePlotAtTheVisualsSize() throws {
        guard let python = Self.pythonWithMatplotlib() else { throw XCTSkip("python3 with pandas and matplotlib is not installed") }
        var env = QueryEnvironment()
        env.allowScripts = true
        env.pythonPath = python
        let environment = env
        let runner = LiveScriptRunner { environment }

        let png = try runner.render(job("import matplotlib.pyplot as plt\nplt.bar(dataset['Region'], dataset['Sum of Amount'])"))
        XCTAssertTrue(ScriptVisuals.isPNG(png))
        // 300 × 200 points: a 300/72 × 200/72 inch figure saved at 144 dpi is 600 × 400 pixels.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 600)
        XCTAssertEqual(image.height, 400)

        XCTAssertThrowsError(try runner.render(job("x = len(dataset)"))) { error in
            XCTAssertEqual(error as? ScriptVisualError, ScriptVisualError(ScriptVisuals.nothingDrawn(.python)))
        }
        XCTAssertThrowsError(try runner.render(job("import facet_no_such_module"))) { error in
            XCTAssertEqual((error as? ScriptVisualError)?.message,
                           "The Python package “facet_no_such_module” isn't installed. Install it with: python3 -m pip install facet_no_such_module")
        }
    }

    // MARK: - Helpers

    private func settle(_ runtime: ScriptVisualRuntime, _ id: UUID) async throws {
        for _ in 0..<200 where runtime.entry(id)?.state == .running {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// python3 on PATH (or the usual places) that imports pandas and matplotlib; nil to skip.
    nonisolated static func pythonWithMatplotlib() -> String? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for folder in path + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let candidate = folder + "/python3"
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: candidate)
            process.arguments = ["-c", "import pandas, matplotlib"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            if process.terminationStatus == 0 { return candidate }
        }
        return nil
    }
}

/// Returns a fixed PNG, fails for the script "fail", and takes a moment for "slow".
private final class StubRunner: ScriptVisualRunner, @unchecked Sendable {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    func render(_ job: ScriptJob) throws -> Data {
        lock.lock(); count += 1; lock.unlock()
        if job.script == "slow" { Thread.sleep(forTimeInterval: 0.2) }
        if job.script == "fail" { throw ScriptVisualError("Stub failure") }
        return Self.png
    }
}
