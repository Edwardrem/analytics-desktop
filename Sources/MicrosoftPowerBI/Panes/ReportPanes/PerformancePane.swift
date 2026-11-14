import SwiftUI
import UniformTypeIdentifiers
import FacetCore
import FacetDesign

// MARK: - Log model

/// The events of one refresh: everything recorded with no more than a second between events.
struct RefreshCluster: Identifiable {
    var id: UUID
    var events: [PerformanceEvent]
    var start: Date { events.first?.timestamp ?? Date() }
    var total: Double { events.reduce(0) { $0 + $1.totalMilliseconds } }

    static func clusters(_ log: [PerformanceEvent]) -> [RefreshCluster] {
        var out: [RefreshCluster] = []
        var previous: Date?
        for e in log.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let p = previous, e.timestamp.timeIntervalSince(p) <= 1, !out.isEmpty {
                out[out.count - 1].events.append(e)
            } else {
                out.append(RefreshCluster(id: e.id, events: [e]))
            }
            previous = e.timestamp
        }
        return out
    }
}

extension DocumentStore {
    /// The recorded event whose results the visual hasn't been drawn with yet (see `DisplayProbe`).
    func eventAwaitingDisplay(_ visualID: UUID) -> UUID? {
        guard performanceRecording, let e = performanceLog.last(where: { $0.visualID == visualID }),
              e.delivered != nil, e.displayMilliseconds == nil else { return nil }
        return e.id
    }
}

extension PerformanceEvent {
    /// Time spent outside the DAX query and the visual's display: preparing the results and analytics.
    var otherMilliseconds: Double { max(0, totalMilliseconds - queryMilliseconds - (displayMilliseconds ?? 0)) }
}

/// Performance log export: `{version, events:[{id, name, visualId, queryMs, displayMs, totalMs, otherMs, dax, timestamp}]}`.
/// `displayMs` is left out for an event whose visual was never drawn with its results.
enum PerformanceExport {
    private struct File: Encodable { var version = 1; var events: [Event] }
    private struct Event: Encodable {
        var id: String, name: String, visualId: String
        var queryMs: Double, displayMs: Double?, totalMs: Double, otherMs: Double
        var dax: String, timestamp: String
    }

    static func data(_ log: [PerformanceEvent]) throws -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let file = File(events: log.map {
            Event(id: $0.id.uuidString, name: $0.visualName, visualId: $0.visualID.uuidString,
                  queryMs: $0.queryMilliseconds, displayMs: $0.displayMilliseconds, totalMs: $0.totalMilliseconds,
                  otherMs: $0.otherMilliseconds,
                  dax: $0.dax, timestamp: iso.string(from: $0.timestamp))
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    @MainActor
    static func run(_ store: DocumentStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(store.displayName) performance.json"
        panel.message = "Export the recorded performance log."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data(store.performanceLog).write(to: url, options: .atomic)
            store.status = StatusMessage(kind: .success, text: "Exported \(store.performanceLog.count) events to “\(url.lastPathComponent)”.")
        } catch {
            store.status = StatusMessage(kind: .error, text: "Couldn't export the performance log. \(error.localizedDescription)")
        }
    }
}

// MARK: - Pane

struct PerformancePane: View {
    enum Sort: String { case order, duration }

    @EnvironmentObject var store: DocumentStore
    @ObservedObject var autoRefresh: AutoRefreshState
    @State private var sort: Sort = .order
    @State private var expandedEvents: Set<UUID> = []
    @State private var optimizeExpanded = false
    @State private var autoRefreshExpanded = false

    private var log: [PerformanceEvent] { store.performanceLog }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Performance", detail: "") {
                IconButton("arrow.clockwise", help: "Refresh visuals") { AppCommands.run("optimize.refreshVisuals", store) }
                Menu {
                    Picker("Sort", selection: $sort) {
                        Text("In order of execution").tag(Sort.order)
                        Text("Slowest first").tag(Sort.duration)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down").frame(width: 28, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Sort events").accessibilityLabel("Sort events")
                IconButton("square.and.arrow.up", help: "Export the log as JSON") { PerformanceExport.run(store) }
                    .disabled(log.isEmpty)
                IconButton("trash", help: "Clear the log") { store.clearPerformanceLog(); expandedEvents = [] }
                    .disabled(log.isEmpty)
            }
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    recorder
                    if log.isEmpty {
                        EmptyState(systemImage: "gauge.with.needle",
                                   title: store.performanceRecording ? "Waiting for visuals" : "Nothing recorded",
                                   message: store.performanceRecording
                                       ? "Interact with the report, or refresh the visuals, to see how long each one takes."
                                       : "Start recording, then refresh the visuals to see where the time goes — query by query.")
                            .frame(height: 170)
                    } else {
                        summary
                        events
                    }
                    Hairline().padding(.horizontal, Design.Space.m)
                    PaneSection(title: "Optimize", expanded: $optimizeExpanded) { optimize }
                    PaneSection(title: "Page auto refresh", expanded: $autoRefreshExpanded) { autoRefreshControls }
                }
            }
        }
        .onAppear { if store.currentPage.autoRefresh.isEnabled { autoRefreshExpanded = true } }
    }

    // MARK: Recording

    private var recorder: some View {
        HStack(spacing: Design.Space.s) {
            Button {
                store.performanceRecording.toggle()
            } label: {
                Label(store.performanceRecording ? "Stop" : "Start recording",
                      systemImage: store.performanceRecording ? "stop.fill" : "record.circle")
            }
            .controlSize(.small)
            .help(store.performanceRecording ? "Stop recording" : "Record how long each visual takes to refresh")
            if store.performanceRecording {
                HStack(spacing: Design.Space.xs) {
                    Circle().fill(Design.Palette.negative).frame(width: 6, height: 6)
                    Text("Recording").font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
        }
        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.m)
    }

    // MARK: Summary

    private var summary: some View {
        let slowest = log.max { $0.totalMilliseconds < $1.totalMilliseconds }
        let total = log.reduce(0) { $0 + $1.totalMilliseconds }
        return HStack(alignment: .top, spacing: Design.Space.l) {
            stat("Slowest visual", slowest.map { $0.totalMilliseconds.durationText } ?? "–", slowest?.visualName ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
            stat("Total time", total.durationText, "\(log.count) event\(log.count == 1 ? "" : "s")")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Design.Space.m).padding(.bottom, Design.Space.m)
    }

    private func stat(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            SectionLabel(label)
            Text(value).font(Design.Typeface.title).monospacedDigit()
            if !detail.isEmpty {
                Text(detail).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Events

    private var events: some View {
        let clusters = RefreshCluster.clusters(log)
        let longest = max(1, log.map(\.totalMilliseconds).max() ?? 1)
        return VStack(alignment: .leading, spacing: 0) {
            // Newest refresh first: it is the one you just caused.
            ForEach(Array(clusters.enumerated().reversed()), id: \.element.id) { index, cluster in
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel("Refresh \(index + 1) · \(cluster.start.formatted(date: .omitted, time: .standard))")
                    Text(cluster.total.durationText).font(Design.Typeface.caption).foregroundStyle(.secondary)
                        .monospacedDigit().fixedSize()
                }
                .padding(.horizontal, Design.Space.m).padding(.top, Design.Space.s).padding(.bottom, Design.Space.xs)
                ForEach(sorted(cluster.events)) { event in
                    eventRow(event, longest: longest)
                }
            }
        }
        .padding(.bottom, Design.Space.m)
    }

    private func sorted(_ events: [PerformanceEvent]) -> [PerformanceEvent] {
        sort == .duration ? events.sorted { $0.totalMilliseconds > $1.totalMilliseconds } : events
    }

    private func eventRow(_ e: PerformanceEvent, longest: Double) -> some View {
        let expanded = expandedEvents.contains(e.id)
        return VStack(alignment: .leading, spacing: Design.Space.xs) {
            Button {
                withAnimation(Design.Motion.quick) {
                    if expanded { expandedEvents.remove(e.id) } else { expandedEvents.insert(e.id) }
                }
            } label: {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.tertiary).frame(width: 10)
                        Text(e.visualName).font(Design.Typeface.body).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Design.Space.s)
                        Text(e.totalMilliseconds.durationText).font(Design.Typeface.body).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    DurationBar(query: e.queryMilliseconds, display: e.displayMilliseconds ?? 0, other: e.otherMilliseconds,
                                scale: longest)
                        .padding(.leading, 14)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(e.visualName), \(e.totalMilliseconds.durationText)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { eventDetail(e).padding(.leading, 14) }
        }
        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
    }

    private func eventDetail(_ e: PerformanceEvent) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            // Stacked, so the three parts fit a narrow pane.
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                legend("DAX query", e.queryMilliseconds.durationText, DurationBar.queryColor)
                    .help("Running the visual's query on the model")
                legend("Visual display", e.displayMilliseconds?.durationText ?? "–", DurationBar.displayColor)
                    .help(e.displayMilliseconds == nil ? "The visual wasn't drawn with these results while recording"
                          : "From the results arriving to the visual being drawn with them")
                legend("Other", e.otherMilliseconds.durationText, DurationBar.otherColor)
                    .help("Preparing the results for the visual, and its analytics")
            }
            if e.dax.isEmpty {
                PaneNote("This visual didn't send a query.")
            } else {
                Text(e.dax)
                    .font(Design.Typeface.mono).textSelection(.enabled)
                    .lineLimit(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Design.Space.s)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(Design.Palette.fill))
                HStack(spacing: Design.Space.m) {
                    Button("Copy query") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e.dax, forType: .string)
                        store.status = StatusMessage(kind: .success, text: "Query copied.")
                    }
                    Button("Open in DAX query view") { openInQueryView(e) }
                }
                .buttonStyle(.link).font(Design.Typeface.caption)
            }
        }
        .padding(.top, Design.Space.xxs).padding(.bottom, Design.Space.s)
    }

    private func legend(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: Design.Space.xs) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(color).frame(width: 8, height: 8)
            Text(label).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(Design.Typeface.caption).monospacedDigit().lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func openInQueryView(_ e: PerformanceEvent) {
        let name = store.report.daxQueries.map(\.name).uniqueName("\(e.visualName) query")
        let tab = DAXQueryTab(name: name, text: e.dax)
        store.mutate("Add DAX Query", invalidates: .layout) { $0.report.daxQueries.append(tab) }
        store.view = .dax
        store.status = StatusMessage(kind: .info, text: "Added “\(name)” to the DAX query view.")
    }

    // MARK: Optimize

    @ViewBuilder
    private var optimize: some View {
        Toggle("Pause visuals", isOn: $store.visualsPaused)
        if store.visualsPaused {
            PaneNote(store.pendingWhilePaused.isEmpty
                     ? "Visuals won't query while you make changes."
                     : "\(store.pendingWhilePaused.count) visual\(store.pendingWhilePaused.count == 1 ? " is" : "s are") waiting to refresh.")
        }
        SectionLabel("Presets").padding(.top, Design.Space.xs)
        HStack(spacing: Design.Space.s) {
            Button("Query reduction") { AppCommands.run("optimize.presetReduction", store) }
                .help("Turn off cross-highlighting and add Apply buttons to slicers and filters")
            Button("Full interactivity") { AppCommands.run("optimize.presetInteractive", store) }
                .help("Cross-highlight by default and apply slicers and filters immediately")
        }
        .controlSize(.small)
        SectionLabel("Query reduction").padding(.top, Design.Space.xs)
        Toggle("Turn off cross-highlighting by default", isOn: setting(\.disableCrossHighlightByDefault, requery: true))
        Toggle("Add an Apply button to slicers", isOn: setting(\.slicerApplyButtons))
        Toggle("Add an Apply button to the Filters pane", isOn: setting(\.filterPaneApplyButton))
    }

    private func setting(_ keyPath: WritableKeyPath<ReportSettings, Bool>, requery: Bool = false) -> Binding<Bool> {
        Binding(get: { store.report.settings[keyPath: keyPath] }, set: { value in
            store.mutate("Change Query Reduction", invalidates: requery ? .visuals(nil) : .layout) {
                $0.report.settings[keyPath: keyPath] = value
            }
        })
    }

    // MARK: Page auto refresh

    @ViewBuilder
    private var autoRefreshControls: some View {
        let spec = store.currentPage.autoRefresh
        Toggle("Refresh “\(store.currentPage.name)” automatically", isOn: Binding(
            get: { spec.isEnabled },
            set: { on in
                store.updatePage(name: on ? "Turn On Page Auto Refresh" : "Turn Off Page Auto Refresh") { $0.autoRefresh.isEnabled = on }
                store.startAutoRefreshIfNeeded()
            }))
        if spec.isEnabled {
            PropertyRow("Every") {
                NumberField(label: "Interval in seconds", value: Binding(
                    get: { spec.intervalSeconds },
                    set: { seconds in
                        store.updatePage(name: "Change Refresh Interval") { $0.autoRefresh.intervalSeconds = seconds }
                        store.startAutoRefreshIfNeeded()
                    }), range: AutoRefreshController.minimumInterval...86_400, step: 5, unit: "seconds")
            }
            PropertyRow("Only when") {
                Picker("Change detection measure", selection: Binding(
                    get: { spec.changeDetectionMeasure.map { "\($0.table)|\($0.name)" } ?? "" },
                    set: { key in
                        let measure = store.model.allMeasures.first { "\($0.table)|\($0.measure.name)" == key }
                        store.updatePage(name: "Change Detection Measure") {
                            $0.autoRefresh.changeDetectionMeasure = measure.map { FieldRef.measure($0.table, $0.measure.name) }
                        }
                        store.startAutoRefreshIfNeeded()
                    })) {
                    Text("Always").tag("")
                    if !store.model.allMeasures.isEmpty { Divider() }
                    ForEach(store.model.allMeasures, id: \.measure.id) { item in
                        Text("\(item.measure.name) changes").tag("\(item.table)|\(item.measure.name)")
                    }
                }
                .labelsHidden().controlSize(.small)
            }
            PaneNote(autoRefreshStatus(spec))
        } else {
            PaneNote("Re-runs this page's queries on a timer while the page is open — useful for wall displays and live data.")
        }
    }

    private func autoRefreshStatus(_ spec: PageRefreshSpec) -> String {
        let what = store.doc.queries.isEmpty ? "Visuals re-query" : "Data refreshes"
        var text = spec.changeDetectionMeasure == nil
            ? "\(what) every \(Int(AutoRefreshController.clamped(spec.intervalSeconds))) s while this page is open."
            : "The measure is checked every \(Int(AutoRefreshController.clamped(spec.intervalSeconds))) s; the page refreshes only when its value changes."
        if let last = autoRefresh.lastRefresh {
            text += " Last refreshed \(last.formatted(date: .omitted, time: .standard))."
        } else if let check = autoRefresh.lastCheck {
            text += " Last checked \(check.formatted(date: .omitted, time: .standard))."
        }
        return text
    }
}

/// Thin bar: DAX query time in the accent colour, visual display in a lighter accent, everything
/// else in a quiet tint, scaled to the slowest event.
struct DurationBar: View {
    static let queryColor = Design.Palette.accent
    static let displayColor = Design.Palette.accent.opacity(0.45)
    static let otherColor = Color.primary.opacity(0.25)

    let query: Double
    var display: Double = 0
    let other: Double
    let scale: Double

    /// The widths of the query, display and other segments in a bar `width` wide.
    static func segments(query: Double, display: Double, other: Double, scale: Double, width: CGFloat) -> [CGFloat] {
        let parts = [query, display, other].map { max(0, $0) }
        let total = parts.reduce(0, +)
        let filled = max(2, width * min(1, total / max(scale, 0.001)))
        return parts.map { total > 0 ? filled * $0 / total : 0 }
    }

    var body: some View {
        GeometryReader { geo in
            let widths = Self.segments(query: query, display: display, other: other, scale: scale, width: geo.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Design.Palette.fill)
                HStack(spacing: 0) {
                    Rectangle().fill(Self.queryColor).frame(width: widths[0])
                    Rectangle().fill(Self.displayColor).frame(width: widths[1])
                    Rectangle().fill(Self.otherColor).frame(width: widths[2])
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
