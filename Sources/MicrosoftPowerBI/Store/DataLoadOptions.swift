import Foundation
import FacetCore

/// The Data load options in effect for a document: the file's own choice (Current file) where it has
/// one, else the global option in Settings.
enum DataLoadOptions {
    private static func flag(_ key: AppSettings.Key, _ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? AppSettings.initial[key.rawValue] as? Bool ?? false
    }

    /// Global ▸ Data load ▸ "Auto date/time for new files".
    static func autoDateTimeForNewFiles(_ defaults: UserDefaults = AppSettings.defaults) -> Bool {
        flag(.autoDateTime, defaults)
    }

    /// "Autodetect new relationships after data is loaded", for this document.
    static func autodetectRelationships(for doc: FacetDocument, defaults: UserDefaults = AppSettings.defaults) -> Bool {
        doc.model.autodetectRelationships ?? flag(.autodetectRelationships, defaults)
    }

    /// The relationships autodetect finds that touch one of the newly loaded tables.
    static func relationships(afterLoading tables: Set<String>, in doc: FacetDocument) -> [Relationship] {
        guard !tables.isEmpty else { return [] }
        let loaded = Set(tables.map { $0.lowercased() })
        return RelationshipLogic.autodetect(doc.model, data: doc.data)
            .filter { loaded.contains($0.fromTable.lowercased()) || loaded.contains($0.toTable.lowercased()) }
    }
}

extension DocumentStore {
    /// A new, empty document, with the options Settings gives new files.
    static func newDocument(defaults: UserDefaults = AppSettings.defaults) -> FacetDocument {
        var doc = FacetDocument()
        doc.model.autoDateTime = DataLoadOptions.autoDateTimeForNewFiles(defaults)
        return doc
    }
}
