import SwiftUI
import FacetCore
import FacetDesign
import FacetCloud

/// UserDefaults keys for global options. Feature code reads them through `AppSettings`.
enum AppSettings {
    static let defaults = UserDefaults.standard
    enum Key: String {
        case appearance
        // Data load
        case detectTypes, autodetectRelationships, autoDateTime, parallelLoading
        // Power Query Editor
        case pqFormulaBar, pqProfilingWholeDataset, pqColumnQuality, pqColumnDistribution, pqColumnProfile, pqMonospaced
        // DirectQuery
        case dqMaxConnections, dqSkipRelationshipValidation
        // Scripting
        case pythonPath, rPath, allowScripts
        // Security & privacy
        case requireNativeQueryApproval, privacyMode
        // Regional
        case modelLanguage, importLocale
        // Diagnostics
        case tracing
        // Auto recovery
        case autoRecovery, autoRecoveryMinutes, autoRecoveryLocation
        // Preview features
        case previewGantt, previewNewQueryEditor, previewCalendarTI, previewUserContextColumns, previewFullTextSearch
        // Developer: agent bridge, Power BI projects
        case mcpServerEnabled, pbipDataCache
    }
    static let initial: [String: Any] = [
        Key.appearance.rawValue: "system", Key.detectTypes.rawValue: true, Key.autodetectRelationships.rawValue: true,
        Key.autoDateTime.rawValue: false, Key.parallelLoading.rawValue: true,
        Key.pqFormulaBar.rawValue: true, Key.pqColumnQuality.rawValue: true, Key.pqColumnDistribution.rawValue: false, Key.pqColumnProfile.rawValue: false,
        Key.pqMonospaced.rawValue: false, Key.dqMaxConnections.rawValue: 10, Key.requireNativeQueryApproval.rawValue: true,
        Key.privacyMode.rawValue: "combine", Key.modelLanguage.rawValue: "en-US", Key.importLocale.rawValue: "en-US",
        Key.autoRecovery.rawValue: true, Key.autoRecoveryMinutes.rawValue: 10, Key.tracing.rawValue: false,
        Key.allowScripts.rawValue: false, Key.previewGantt.rawValue: true, Key.previewNewQueryEditor.rawValue: true, Key.previewCalendarTI.rawValue: true,
        Key.previewUserContextColumns.rawValue: true, Key.previewFullTextSearch.rawValue: true,
        Key.mcpServerEnabled.rawValue: false, Key.pbipDataCache.rawValue: false, Key.autoRecoveryLocation.rawValue: "",
    ]
    static func registerDefaults() { defaults.register(defaults: initial) }
    static func bool(_ k: Key) -> Bool { defaults.bool(forKey: k.rawValue) }
    static func int(_ k: Key) -> Int { defaults.integer(forKey: k.rawValue) }
    static func string(_ k: Key) -> String { defaults.string(forKey: k.rawValue) ?? "" }
}

/// Extra settings tabs contributed by other features (Microsoft account, Assistant…).
@MainActor
enum SettingsSections {
    struct Section: Identifiable { var id: String { title }; var title: String; var symbol: String; var view: () -> AnyView }
    static var extra: [Section] = []
}

@MainActor
enum SettingsFeature {
    static func register() {
        AppSettings.registerDefaults()
        Features.settingsBuilder = { AnyView(SettingsView()) }
        PreviewFeatures.observe()
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            CurrentFileSettings().tabItem { Label("Current File", systemImage: "doc.badge.gearshape") }
            DataSettings().tabItem { Label("Data", systemImage: "cylinder.split.1x2") }
            SecuritySettings().tabItem { Label("Security", systemImage: "lock.shield") }
            ScriptingSettings().tabItem { Label("Scripting", systemImage: "chevron.left.forwardslash.chevron.right") }
            ForEach(SettingsSections.extra) { s in s.view().tabItem { Label(s.title, systemImage: s.symbol) } }
            PreviewSettings().tabItem { Label("Preview", systemImage: "flask") }
            DiagnosticsSettings().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 620, height: 460)
    }
}

private struct Toggled: View {
    let title: String; let key: AppSettings.Key; var help: String = ""
    @AppStorage private var value: Bool
    init(_ title: String, _ key: AppSettings.Key, help: String = "") {
        self.title = title; self.key = key; self.help = help
        _value = AppStorage(wrappedValue: (AppSettings.initial[key.rawValue] as? Bool) ?? false, key.rawValue)
    }
    var body: some View {
        Toggle(isOn: $value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !help.isEmpty { Text(help).font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .managed(key)
    }
}

/// A plain statement in a settings section.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppSettings.Key.appearance.rawValue) private var appearance = "system"
    @AppStorage(AppSettings.Key.modelLanguage.rawValue) private var modelLanguage = "en-US"
    @AppStorage(AppSettings.Key.importLocale.rawValue) private var importLocale = "en-US"
    @AppStorage(AppSettings.Key.autoRecoveryMinutes.rawValue) private var minutes = 10
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Window theme", selection: $appearance) {
                    Text("Match system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
                .managed(.appearance)
            }
            Section("Regional") {
                VStack(alignment: .leading, spacing: 2) {
                    Picker("Model language for new files", selection: $modelLanguage) { CulturePicker.options }
                    Note("How numbers and dates are formatted, and the culture DAX's FORMAT and USERCULTURE() use. Change an open file's own language in Current File.")
                }
                .managed(.modelLanguage)
                VStack(alignment: .leading, spacing: 2) {
                    Picker("Locale for import", selection: $importLocale) { CulturePicker.options }
                    Note("How text from sources is read as numbers and dates when data is loaded, for every file.")
                }
                .managed(.importLocale)
            }
            Section("Auto recovery") {
                Toggled("Store recovery copies of open documents", .autoRecovery,
                        help: "Documents with unsaved changes are copied regularly and offered back if \(AppIdentity.name) quits before you save.")
                Stepper("Every \(minutes) minute\(minutes == 1 ? "" : "s")", value: $minutes, in: 1...60)
                    .managed(.autoRecoveryMinutes)
                RecoveryLocationRow().managed(.autoRecoveryLocation)
            }
            Section("Updates and usage data") {
                Note("\(AppIdentity.name) has no automatic updater: new versions come from wherever you installed it. It sends no usage data or telemetry, and never sends your data or documents anywhere you didn't ask.")
            }
        }.formStyle(.grouped)
    }
}

/// The cultures offered for the model language and the locale for import.
enum CulturePicker {
    static let cultures = ["en-US", "en-GB", "en-ZA", "fr-FR", "de-DE", "es-ES", "pt-BR", "it-IT", "nl-NL", "ja-JP", "zh-CN", "sn-ZW"]
    static func name(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }
    @ViewBuilder static var options: some View {
        ForEach(cultures, id: \.self) { Text(name($0)).tag($0) }
    }
}

/// Where recovery copies go: the default folder, or one the user chooses.
private struct RecoveryLocationRow: View {
    @AppStorage(AppSettings.Key.autoRecoveryLocation.rawValue) private var location = ""
    private var folder: URL { AutoRecovery.shared.directory }
    var body: some View {
        LabeledContent("Location") {
            HStack {
                Text((folder.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary).help(folder.path)
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                    p.message = "Choose where recovery copies are kept."
                    if p.runModal() == .OK, let u = p.url { location = u.path }
                }
                Button("Show") {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(folder)
                }
                if !location.isEmpty { Button("Use Default") { location = "" } }
            }
        }
    }
}

private struct DataSettings: View {
    @AppStorage(AppSettings.Key.dqMaxConnections.rawValue) private var connections = 10
    var body: some View {
        Form {
            Section("Data load") {
                Toggled("Detect column types and headers for unstructured sources", .detectTypes)
                Toggled("Autodetect new relationships after data is loaded", .autodetectRelationships,
                        help: "For files that haven't chosen for themselves in Current File.")
                Toggled("Auto date/time for new files", .autoDateTime, help: "Adds hidden date hierarchies. Larger models; prefer a date table.")
                Toggled("Load tables in parallel", .parallelLoading,
                        help: "Up to \(max(2, ProcessInfo.processInfo.activeProcessorCount)) tables load at once. When off, a refresh loads one table at a time.")
            }
            Section("Power Query Editor") {
                Toggled("Show the formula bar", .pqFormulaBar)
                Toggled("Column quality", .pqColumnQuality)
                Toggled("Column distribution", .pqColumnDistribution)
                Toggled("Column profile", .pqColumnProfile)
                Toggled("Profile the whole dataset, not the first 1,000 rows", .pqProfilingWholeDataset)
                Toggled("Monospaced data preview", .pqMonospaced)
            }
            Section("DirectQuery") {
                Stepper("Maximum connections per data source: \(connections)", value: $connections, in: 1...30)
                    .managed(.dqMaxConnections)
                Toggled("Edit relationships without validating against the source", .dqSkipRelationshipValidation,
                        help: "Creating or editing a relationship doesn't read DirectQuery tables' rows to check its cardinality.")
                Note("Measures over DirectQuery tables run in \(AppIdentity.name)'s engine on the rows the source returns, so every DAX function is available: there is no restricted mode to turn off.")
            }
        }.formStyle(.grouped)
    }
}

private struct SecuritySettings: View {
    @AppStorage(AppSettings.Key.privacyMode.rawValue) private var privacy = "combine"
    var body: some View {
        Form {
            Section("Queries") {
                Toggled("Ask before running native database queries", .requireNativeQueryApproval)
            }
            Section("Extensions") {
                Note("\(AppIdentity.name) has no custom data connectors or custom visuals, so there is nothing to certify or warn about. Connections use macOS's own certificate checks.")
            }
            Section("Privacy levels") {
                Picker("Combining data", selection: $privacy) {
                    Text("Combine according to each source's privacy level").tag("combine")
                    Text("Always ask per file").tag("file")
                    Text("Ignore privacy levels (faster, may expose data)").tag("ignore")
                }
                .managed(.privacyMode)
                Text("Privacy levels stop data from a private source being sent to another source when queries are combined.")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
            Section("Credentials") {
                Text("Account tokens and the assistant key are stored in your macOS Keychain, never in documents. Data sources are read without credentials: Web and OData use anonymous access.")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct ScriptingSettings: View {
    @AppStorage(AppSettings.Key.pythonPath.rawValue) private var python = ""
    @AppStorage(AppSettings.Key.rPath.rawValue) private var r = ""
    var body: some View {
        Form {
            Section {
                Toggled("Allow Python and R scripts to run", .allowScripts,
                        help: "Scripts run on this Mac with your permissions. Only enable for documents you trust.")
            }
            Section("Python") {
                HStack { TextField("Interpreter", text: $python, prompt: Text(detected("python3") ?? "/usr/bin/python3")); Button("Choose…") { choose { python = $0 } } }
                    .managed(.pythonPath)
                Text(python.isEmpty ? "Using \(detected("python3") ?? "no Python found on this Mac")." : "").font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
            Section("R") {
                HStack { TextField("Rscript", text: $r, prompt: Text(detected("Rscript") ?? "Not installed")); Button("Choose…") { choose { r = $0 } } }
                    .managed(.rPath)
                Text(r.isEmpty ? (detected("Rscript").map { "Using \($0)." } ?? "R isn't installed. Install it from r-project.org to use R scripts and visuals.") : "")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private func detected(_ tool: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/Library/Frameworks/R.framework/Resources/bin"]
            .map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private func choose(_ set: (String) -> Void) {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.directoryURL = URL(fileURLWithPath: "/usr/bin")
        if p.runModal() == .OK, let u = p.url { set(u.path) }
    }
}

private struct PreviewSettings: View {
    var body: some View {
        Form {
            Section(header: Text("Preview features"),
                    footer: Note("Preview features may change. Open documents follow a change at once; the Power Query Editor follows it the next time it opens.")) {
                ForEach(PreviewFeatures.all, id: \.key) { f in Toggled(f.title, f.key, help: f.help) }
            }
        }.formStyle(.grouped)
    }
}

private struct DiagnosticsSettings: View {
    var body: some View {
        let info = Bundle.main.infoDictionary
        Form {
            Section("Version") {
                LabeledContent(AppIdentity.name, value: "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "dev"))")
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Architecture", value: architecture)
                LabeledContent("Memory", value: ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
            }
            Section("Tracing") {
                Toggled("Enable tracing", .tracing,
                        help: "Writes how long loading the model, refreshing, DirectQuery reads and visual queries take, with row counts, to the Traces folder. Never data values, DAX or M text, or credentials.")
                Button("Open Traces Folder") {
                    let url = TraceLog.shared.directory
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
                Button("Open Crash Reports") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DiagnosticReports")) }
            }
            Section("Self-check") {
                SelfCheckRow()
            }
        }.formStyle(.grouped)
    }
    private var architecture: String {
        #if arch(arm64)
        return "Apple silicon (arm64)"
        #else
        return "Intel (x86_64)"
        #endif
    }
}

/// Runs the offline FacetCloud self-check and reports the result.
private struct SelfCheckRow: View {
    @State private var report: String?
    @State private var running = false

    var body: some View {
        HStack {
            Button("Run Self-Check") {
                running = true
                report = nil
                let result = FacetCloudSelfCheck.runReportBlocking()
                running = false
                if result.failures.isEmpty {
                    report = "All \(result.passed) checks passed."
                } else {
                    report = "\(result.failures.count) of \(result.passed + result.failures.count) checks failed:\n" + result.failures.prefix(8).joined(separator: "\n")
                }
            }
            .disabled(running)
            if running { ProgressView().controlSize(.small) }
        }
        if let report {
            Text(report).font(Design.Typeface.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
