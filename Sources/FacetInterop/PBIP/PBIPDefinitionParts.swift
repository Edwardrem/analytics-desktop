import Foundation
import FacetCore

public extension PBIPProject {
    /// The files the Fabric item API takes to create or update a document's semantic model and report: the contents of
    /// the project's `.SemanticModel` and `.Report` folders, with paths relative to each folder. Files that only make sense
    /// on this Mac (`.platform` identity, `.pbi` settings and caches) are left out. The report's `definition.pbir` still
    /// points at the local model folder; the publisher replaces it with a binding to the published model.
    static func definitionParts(for document: FacetDocument, name: String, includeFacetAnnotations: Bool = true)
        -> (model: [(path: String, data: Data)], report: [(path: String, data: Data)], warnings: [ImportWarning]) {
        let safe = DocumentPackage.fileName(for: name)
        let generated = files(for: document, name: safe, options: WriteOptions(includeFacetDataCache: false, includeFacetAnnotations: includeFacetAnnotations))
        func folder(_ suffix: String) -> [(path: String, data: Data)] {
            let prefix = "\(safe).\(suffix)/"
            return generated.files.compactMap { file in
                guard file.path.hasPrefix(prefix) else { return nil }
                let rel = String(file.path.dropFirst(prefix.count))
                let parts = rel.split(separator: "/")
                guard rel != ".platform", !parts.contains(".pbi") else { return nil }
                return (rel, file.data)
            }
        }
        // Data never goes up with a definition, so the project's note about table data does not apply here.
        let warnings = generated.warnings.filter { $0.severity != .info }
        return (folder("SemanticModel"), folder("Report"), warnings)
    }
}
