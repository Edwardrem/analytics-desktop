import Foundation
import FacetCore

/// Runs Python and R scripts as query steps. Tables travel as CSV files in a private temporary folder.
enum ScriptRunner {
    static let pythonWrapper = """
    import os, sys
    try:
        import pandas
    except ImportError:
        sys.stderr.write("The pandas package is required to run Python scripts. Install it with: python3 -m pip install pandas")
        sys.exit(3)
    _folder = sys.argv[1]
    for _f in os.listdir(os.path.join(_folder, "in")):
        globals()[_f[:-4]] = pandas.read_csv(os.path.join(_folder, "in", _f))
    exec(compile(open(os.path.join(_folder, "script"), encoding="utf-8").read(), "script", "exec"))
    for _k, _v in list(globals().items()):
        if isinstance(_v, pandas.DataFrame) and not _k.startswith("_"):
            _v.to_csv(os.path.join(_folder, "out", _k + ".csv"), index=False)
    """
    static let rWrapper = """
    .folder <- commandArgs(trailingOnly = TRUE)[1]
    for (.f in list.files(file.path(.folder, "in"))) assign(sub("\\\\.csv$", "", .f), read.csv(file.path(.folder, "in", .f), check.names = FALSE))
    source(file.path(.folder, "script"))
    for (.n in ls()) { .v <- get(.n); if (is.data.frame(.v)) write.csv(.v, file.path(.folder, "out", paste0(.n, ".csv")), row.names = FALSE) }
    """

    static func find(_ names: [String], configured: String?, environment: QueryEnvironment, language: String) throws -> String {
        if let configured, !configured.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: configured) else {
                throw MError.dataSource("The \(language) interpreter '\(configured)' wasn't found. Check the \(language) scripting path in Options.")
            }
            return configured
        }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for folder in environment.toolSearchPaths + path + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            for n in names where FileManager.default.isExecutableFile(atPath: folder + "/" + n) { return folder + "/" + n }
        }
        throw MError.dataSource("No \(language) installation was found. Install \(language) or set its path in Options.")
    }

    static func csv(_ t: MTable, culture: String) throws -> String {
        func field(_ v: MValue) throws -> String { MText.csvQuoted(v.isNull ? "" : try MConvert.text(v.forcedCell(), culture: "en-US"), delimiter: ",") }
        var out = t.columnNames.map { MText.csvQuoted($0, delimiter: ",") }.joined(separator: ",") + "\n"
        for row in try t.rows { out += try row.map(field).joined(separator: ",") + "\n" }
        return out
    }

    static func run(language: String, executable: String, arguments: [String], wrapper: String, script: String, inputs: MRecord?, _ ctx: MInterpreter) throws -> MValue {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("facet-script-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for sub in ["in", "out"] { try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true) }
        try Data(wrapper.utf8).write(to: folder.appendingPathComponent("wrapper"))
        try Data(script.utf8).write(to: folder.appendingPathComponent("script"))
        if let inputs {
            for (name, value) in zip(inputs.names, try inputs.forcedValues()) {
                guard case .table(let t) = value else { throw MError("\(language) script inputs must be tables ('\(name)' is a \(value.typeName)).") }
                guard MSyntax.isPlainIdentifier(name), !name.contains(".") else { throw MError("'\(name)' can't be used as a \(language) variable name.") }
                try Data(try csv(t, culture: ctx.culture).utf8).write(to: folder.appendingPathComponent("in/\(name).csv"))
            }
        }
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments + [folder.appendingPathComponent("wrapper").path, folder.path]
        process.currentDirectoryURL = folder
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { throw MError.dataSource("The \(language) interpreter '\(executable)' couldn't be started: \(error.localizedDescription)") }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MError.dataSource("The \(language) script failed: \(message.isEmpty ? "exit status \(process.terminationStatus)" : message)")
        }
        var rows: [[MValue]] = []
        let outputs = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("out").path))?.sorted() ?? []
        for file in outputs where file.hasSuffix(".csv") {
            let text = try MText.decode(try Data(contentsOf: folder.appendingPathComponent("out/" + file)), codePage: nil)
            var parsed = CsvParser.parse(text, delimiter: ",", quotedLineBreaks: true)
            let header = parsed.isEmpty ? [] : parsed.removeFirst()
            var table = DataTable(columnNames: MLib.uniqued(header), rows: parsed.map { r in header.indices.map { $0 < r.count ? Value.string(r[$0]) : .null } },
                                  types: header.map { _ in .text })
            table.detectAndConvertTextTypes()
            rows.append([.text(String(file.dropLast(4))), .table(MTable(table))])
        }
        return .table(MTable(names: ["Name", "Value"], types: [.text, .anyTable], rows: rows))
    }
}

extension MLibrary {
    static func registerScripts(_ lib: MLibrary) {
        func script(_ name: String, language: String, executables: [String], arguments: [String], wrapper: String, path: @escaping (QueryEnvironment) -> String?) {
            lib.fn(name, 1...2) { a, ctx in
                guard ctx.environment.allowScripts else {
                    throw MError("\(language) scripts are turned off. Allow script execution for this file to run the step.", reason: "Formula.Firewall")
                }
                let exe = try ScriptRunner.find(executables, configured: path(ctx.environment), environment: ctx.environment, language: language)
                return try ScriptRunner.run(language: language, executable: exe, arguments: arguments, wrapper: wrapper, script: try a.text(0),
                                            inputs: try a.optRecord(1), ctx)
            }
        }
        script("Python.Execute", language: "Python", executables: ["python3", "python"], arguments: [], wrapper: ScriptRunner.pythonWrapper) { $0.pythonPath }
        script("R.Execute", language: "R", executables: ["Rscript"], arguments: ["--vanilla"], wrapper: ScriptRunner.rWrapper) { $0.rPath }
    }
}
