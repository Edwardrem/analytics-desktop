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
        case detectTypes, autodetectRelationships, autoDateTime, backgroundPreviews, parallelLoading, cacheLimitMB
        // Power Query Editor
        case pqFormulaBar, pqProfilingWholeDataset, pqColumnQuality, pqColumnDistribution, pqColumnProfile, pqMonospaced
        // DirectQuery
        case dqMaxConnections, dqUnrestrictedMeasures, dqSkipRelationshipValidation
        // Scripting
        case pythonPath, rPath, allowScripts
        // Security & privacy
        case requireNativeQueryApproval, connectorTrust, certificateChecks, warnUncertifiedVisuals, privacyMode
        // Regional
        case appLanguage, modelLanguage, importLocale
        // Updates, diagnostics
        case updateNotifications, usageData, tracing
        // Auto recovery
        case autoRecovery, autoRecoveryMinutes, autoRecoveryLocation
        // Preview features
        case previewGantt, previewNewQueryEditor, previewCalendarTI, previewUserContextColumns, previewFullTextSearch
        // Developer: agent bridge, Power BI projects
        case mcpServerEnabled, pbipDataCache
    }
    static let initial: [String: Any] = [
        Key.appearance.rawValue: "system", Key.detectTypes.rawValue: true, Key.autodetectRelationships.rawValue: true,
        Key.autoDateTime.rawValue: false, Key.backgroundPreviews.rawValue: true, Key.parallelLoading.rawValue: true, Key.cacheLimitMB.rawValue: 4096,
        Key.pqFormulaBar.rawValue: true, Key.pqColumnQuality.rawValue: true, Key.pqColumnDistribution.rawValue: false, Key.pqColumnProfile.rawValue: false,
        Key.pqMonospaced.rawValue: false, Key.dqMaxConnections.rawValue: 10, Key.requireNativeQueryApproval.rawValue: true,
        Key.connectorTrust.rawValue: "certified", Key.certificateChecks.rawValue: true, Key.warnUncertifiedVisuals.rawValue: true,
        Key.privacyMode.rawValue: "combine", Key.appLanguage.rawValue: "system", Key.modelLanguage.rawValue: "en-US", Key.importLocale.rawValue: "en-US",
        Key.updateNotifications.rawValue: true, Key.usageData.rawValue: false, Key.autoRecovery.rawValue: true, Key.autoRecoveryMinutes.rawValue: 10,
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
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
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
                if !help.isEmpty { Text(help).font(Design.Typeface.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppSettings.Key.appearance.rawValue) private var appearance = "system"
    @AppStorage(AppSettings.Key.appLanguage.rawValue) private var language = "system"
    @AppStorage(AppSettings.Key.modelLanguage.rawValue) private var modelLanguage = "en-US"
    @AppStorage(AppSettings.Key.importLocale.rawValue) private var importLocale = "en-US"
    @AppStorage(AppSettings.Key.autoRecoveryMinutes.rawValue) private var minutes = 10
    private let locales = ["en-US", "en-GB", "en-ZA", "fr-FR", "de-DE", "es-ES", "pt-BR", "it-IT", "nl-NL", "ja-JP", "zh-CN", "sn-ZW"]
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Window theme", selection: $appearance) {
                    Text("Match system").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
            }
            Section("Regional") {
                Picker("Model language", selection: $modelLanguage) { ForEach(locales, id: \.self) { Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0) } }
                Picker("Locale for import", selection: $importLocale) { ForEach(locales, id: \.self) { Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0) } }
            }
            Section("Auto recovery") {
                Toggled("Store recovery copies of open documents", .autoRecovery,
                        help: "Documents with unsaved changes are copied regularly and offered back if \(AppIdentity.name) quits before you save.")
                Stepper("Every \(minutes) minute\(minutes == 1 ? "" : "s")", value: $minutes, in: 1...60)
                RecoveryLocationRow()
            }
            Section("Updates") {
                Toggled("Tell me when an update is available", .updateNotifications)
                Toggled("Share anonymous usage data", .usageData, help: "Off by default. \(AppIdentity.name) never sends your data or documents.")
            }
        }.formStyle(.grouped)
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
    @AppStorage(AppSettings.Key.cacheLimitMB.rawValue) private var cache = 4096
    @AppStorage(AppSettings.Key.dqMaxConnections.rawValue) private var connections = 10
    var body: some View {
        Form {
            Section("Data load") {
                Toggled("Detect column types and headers for unstructured sources", .detectTypes)
                Toggled("Autodetect new relationships after data is loaded", .autodetectRelationships)
                Toggled("Auto date/time for new documents", .autoDateTime, help: "Adds hidden date hierarchies. Larger models; prefer a date table.")
                Toggled("Load data previews in the background", .backgroundPreviews)
                Toggled("Load tables in parallel", .parallelLoading)
                Stepper("Data cache limit: \(cache) MB", value: $cache, in: 256...65536, step: 256)
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
                Toggled("Allow unrestricted measures", .dqUnrestrictedMeasures)
                Toggled("Edit relationships without validating against the source", .dqSkipRelationshipValidation)
            }
        }.formStyle(.grouped)
    }
}

private struct SecuritySettings: View {
    @AppStorage(AppSettings.Key.connectorTrust.rawValue) private var trust = "certified"
    @AppStorage(AppSettings.Key.privacyMode.rawValue) private var privacy = "combine"
    var body: some View {
        Form {
            Section("Queries") {
                Toggled("Ask before running native database queries", .requireNativeQueryApproval)
                Toggled("Check certificate revocation for connections", .certificateChecks)
            }
            Section("Extensions") {
                Picker("Data connectors", selection: $trust) {
                    Text("Only certified connectors").tag("certified")
                    Text("Allow any connector, with a warning").tag("any")
                }
                Toggled("Warn before loading uncertified custom visuals", .warnUncertifiedVisuals)
            }
            Section("Privacy levels") {
                Picker("Combining data", selection: $privacy) {
                    Text("Combine according to each source's privacy level").tag("combine")
                    Text("Always ask per file").tag("file")
                    Text("Ignore privacy levels (faster, may expose data)").tag("ignore")
                }
                Text("Privacy levels stop data from a private source being sent to another source when queries are combined.")
                    .font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
            Section("Credentials") {
                Text("Data source credentials and account tokens are stored in your macOS Keychain, never in documents.")
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
                Text(python.isEmpty ? "Using \(detected("python3") ?? "no Python found on this Mac")." : "").font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
            Section("R") {
                HStack { TextField("Rscript", text: $r, prompt: Text(detected("Rscript") ?? "Not installed")); Button("Choose…") { choose { r = $0 } } }
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
            Section(footer: Text("Preview features may change. Some need a restart.").font(Design.Typeface.caption).foregroundStyle(.secondary)) {
                Toggled("Gantt chart visual", .previewGantt)
                Toggled("Diagram, schema and script views in the Power Query Editor", .previewNewQueryEditor)
                Toggled("Calendar-based time intelligence", .previewCalendarTI)
                Toggled("User-context-aware calculated columns", .previewUserContextColumns)
                Toggled("String indexing and full-text search functions", .previewFullTextSearch)
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
                Toggled("Enable tracing", .tracing, help: "Writes engine timings to the traces folder.")
                Button("Open Traces Folder") {
                    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("\(AppIdentity.name)/Traces")
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
