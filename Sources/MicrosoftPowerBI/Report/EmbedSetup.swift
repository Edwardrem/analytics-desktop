import Foundation
import FacetCore
import FacetVisuals

/// Setting up the visuals that show content from a Microsoft service: a paginated report, a
/// Power Apps app or a scorecard (shown in a web view, where readers sign in to the service), and
/// a Power Automate flow (its button posts the visual's rows to the flow's HTTP trigger).
/// `VisualSpec.content` holds the https address; an ID is turned into the service's address.
enum EmbedSetup {
    /// The Format pane card that sets the source.
    static let card = "embedSource"
    static let types: Set<VisualType> = [.paginatedReport, .powerApps, .powerAutomate, .metrics]

    enum Problem: Error, Equatable {
        case missing(String)
        case notHTTPS
        case unrecognised(String)

        var message: String {
            switch self {
            case .missing(let s), .unrecognised(let s): return s
            case .notHTTPS: return "Only https:// addresses can be shown or called. Use the address the service gives you, which starts with https://."
            }
        }
    }

    /// The label of the entry field.
    static func entryLabel(_ type: VisualType) -> String {
        switch type {
        case .paginatedReport: return "Report ID or URL"
        case .powerApps: return "App ID or link"
        case .powerAutomate: return "Flow URL"
        default: return "Scorecard ID or URL"
        }
    }

    static func placeholder(_ type: VisualType) -> String {
        type == .powerAutomate ? "https://…/triggers/manual/paths/invoke…" : "ID or https:// address"
    }

    /// What the service needs and how readers see the content.
    static func requirement(_ type: VisualType) -> String {
        switch type {
        case .paginatedReport:
            return "Shows a paginated report published to the Power BI service. Readers sign in to the service inside the visual; \(AppIdentity.name) can't render .rdl reports on its own."
        case .powerApps:
            return "Runs an app from Power Apps inside the page. Readers sign in to Power Apps inside the visual. Find the app ID under the app's Details in Power Apps."
        case .powerAutomate:
            return "Use a flow that starts with “When an HTTP request is received”, and paste its HTTP POST URL. The button posts this visual's rows to the flow as a JSON array, one object per row."
        default:
            return "Shows a scorecard from the Power BI service. Readers sign in inside the visual. The IDs are in the scorecard's address: …/groups/<workspace ID>/scorecards/<scorecard ID>."
        }
    }

    /// The https address for what the author entered: a full https URL as it is, or an ID turned
    /// into the service's address (a scorecard also needs its workspace ID). A flow needs its URL.
    static func url(for type: VisualType, entry: String, workspace: String = "") -> Result<URL, Problem> {
        let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.missing("Enter the \(entryLabel(type).lowercased()) first.")) }
        if text.contains("://") || text.lowercased().hasPrefix("http") || text.contains(":") {
            guard let url = EmbedAddress.httpsURL(from: text) else { return .failure(.notHTTPS) }
            return .success(url)
        }
        guard let id = UUID(uuidString: text)?.uuidString.lowercased() else {
            if type == .powerAutomate { return .failure(.unrecognised("Paste the flow's HTTP POST URL: copy it from the trigger in Power Automate. It starts with https://.")) }
            return .failure(.unrecognised("That isn't an ID or an address. An ID looks like 1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d; an address starts with https://."))
        }
        let address: String
        switch type {
        case .paginatedReport:
            address = "https://app.powerbi.com/rdlEmbed?reportId=\(id)&autoAuth=true"
        case .powerApps:
            address = "https://apps.powerapps.com/play/\(id)?source=iframe"
        case .metrics:
            guard let ws = UUID(uuidString: workspace.trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString.lowercased() else {
                return .failure(.missing("Enter the workspace ID as well: it follows /groups/ in the scorecard's address."))
            }
            address = "https://app.powerbi.com/groups/\(ws)/scorecards/\(id)"
        default:
            return .failure(.unrecognised("A flow is called by its HTTP POST URL, not an ID. Copy the URL from the flow's trigger."))
        }
        guard let url = URL(string: address) else { return .failure(.notHTTPS) }
        return .success(url)
    }

    // MARK: - Running a flow

    /// The visual's rows with its fields' captions as names, as Export data writes them.
    static func captioned(_ data: VisualData) -> DataTable {
        var table = data.table
        for i in table.columns.indices { table.columns[i].name = data.fields[safe: i]??.caption ?? table.columns[i].name }
        return table
    }

    /// The POST that starts a flow with the visual's rows.
    static func flowRequest(url: URL, data: VisualData) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = DataExporters.json(captioned(data))
        return request
    }

    /// What the author sees once the flow's trigger answered (or didn't).
    static func flowResult(status: Int?, error: Error?, rows: Int, name: String) -> StatusMessage {
        if let error {
            return StatusMessage(kind: .error, text: "The flow for “\(name)” couldn't be reached: \(error.localizedDescription)")
        }
        let code = status ?? 0
        if (200..<300).contains(code) {
            return StatusMessage(kind: .success, text: "Started the flow for “\(name)” with \(rows) \(rows == 1 ? "row" : "rows").")
        }
        let reason: String
        switch code {
        case 401, 403: reason = "the flow refused the call. Copy the trigger's URL again: it includes its signature."
        case 404: reason = "no flow answers at that address. Check that the flow is turned on and the URL is complete."
        case 429: reason = "the flow is being called too often. Try again in a moment."
        default: reason = "the flow answered with HTTP \(code)."
        }
        return StatusMessage(kind: .warning, text: "The flow for “\(name)” didn't start: \(reason)")
    }
}

extension DocumentStore {
    /// Opens the Format pane at the visual's Source card.
    func setUpEmbed(_ id: UUID) {
        selection = withGroupMembers([id])
        FormatFocus.shared.open(EmbedSetup.card, tab: .visual, in: self)
    }

    /// Posts the visual's current rows to its flow's HTTP trigger and reports the outcome.
    func runFlow(_ spec: VisualSpec) {
        guard let url = EmbedAddress.httpsURL(from: spec.content) else {
            status = StatusMessage(kind: .warning, text: "Set the flow's URL in Format › Source first.")
            return
        }
        guard let data = visualData[spec.id], data.error == nil else {
            status = StatusMessage(kind: .warning, text: "“\(spec.name)” has no data to send yet. Wait for it to load, then run the flow again.")
            return
        }
        let request = EmbedSetup.flowRequest(url: url, data: data)
        let rows = data.table.rowCount, name = spec.name
        status = StatusMessage(kind: .info, text: "Running the flow for “\(name)”…")
        Task { @MainActor [weak self] in
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                self?.status = EmbedSetup.flowResult(status: (response as? HTTPURLResponse)?.statusCode, error: nil, rows: rows, name: name)
            } catch {
                self?.status = EmbedSetup.flowResult(status: nil, error: error, rows: rows, name: name)
            }
        }
    }
}
