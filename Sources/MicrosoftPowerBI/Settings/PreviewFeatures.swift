import Foundation
import FacetCore
import FacetDAX

/// Settings ▸ Preview. Each toggle gates its feature: the engine's preview features are applied to every open
/// document as soon as a toggle changes; the Gantt visual leaves the visual gallery and the Insert menu.
/// "Diagram, schema and script views" is read by the Power Query Editor itself.
@MainActor
enum PreviewFeatures {
    struct Feature {
        var key: AppSettings.Key
        var title: String
        var help: String
    }

    static let all: [Feature] = [
        Feature(key: .previewGantt, title: "Gantt chart visual",
                help: "When off, the Gantt visual isn't offered for new visuals. Gantt visuals already in a report still show."),
        Feature(key: .previewNewQueryEditor, title: "Diagram, schema and script views in the Power Query Editor",
                help: "When off, the Power Query Editor shows only its data view."),
        Feature(key: .previewCalendarTI, title: "Calendar-based time intelligence",
                help: "Time intelligence functions accept a calendar defined on a table (Modeling ▸ Calendars) in place of a date column."),
        Feature(key: .previewUserContextColumns, title: "User-context-aware calculated columns",
                help: "Calculated columns and tables see the user in View as (USERNAME() and USERPRINCIPALNAME()). When off they are computed as at refresh, with no View-as user."),
        Feature(key: .previewFullTextSearch, title: "String indexing and full-text search functions",
                help: "TEXTSEARCH, which answers from a word index of a column's text."),
    ]

    static func isOn(_ key: AppSettings.Key, _ defaults: UserDefaults = AppSettings.defaults) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? (AppSettings.initial[key.rawValue] as? Bool ?? true)
    }

    /// Whether the visual gallery and Insert menu offer a visual type.
    nonisolated static func offers(_ type: VisualType) -> Bool { offers(type, defaults: AppSettings.defaults) }
    nonisolated static func offers(_ type: VisualType, defaults: UserDefaults) -> Bool {
        type != .gantt || (defaults.object(forKey: AppSettings.Key.previewGantt.rawValue) as? Bool ?? true)
    }

    /// The engine's preview features, from the settings.
    static func engineFeatures(_ defaults: UserDefaults = AppSettings.defaults) -> DAXFeatures {
        DAXFeatures(calendarTimeIntelligence: isOn(.previewCalendarTI, defaults),
                    textSearch: isOn(.previewFullTextSearch, defaults),
                    userContextColumns: isOn(.previewUserContextColumns, defaults))
    }

    /// Applies the settings to new engines and, when they changed, reloads every open document's engine.
    /// Returns whether anything changed.
    @discardableResult
    static func apply(_ defaults: UserDefaults = AppSettings.defaults, stores: [DocumentStore]? = nil) -> Bool {
        let features = engineFeatures(defaults)
        guard features != DAXFeatures.current else { return false }
        DAXFeatures.current = features
        for store in stores ?? StoreRegistry.shared.all { store.reloadEngine() }
        return true
    }

    private static var observer: NSObjectProtocol?
    /// Follows the settings for the rest of the session.
    static func observe() {
        apply()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = apply() }
        }
    }
}
