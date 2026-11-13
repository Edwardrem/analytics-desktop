import SwiftUI
import UniformTypeIdentifiers
import FacetCore

/// Reading and writing theme files.
///
/// `importer` and `exporter` are indirection points: they default to Facet's native `ThemeSpec` JSON, and the
/// interop bridge replaces them to read and write Power BI theme JSON (falling back to `nativeImport` /
/// `nativeExport` as it sees fit).
@MainActor
enum ThemeIO {
    static var importer: ((URL) throws -> ThemeSpec)? = { try nativeImport($0) }
    static var exporter: ((ThemeSpec, URL) throws -> Void)? = { try nativeExport($0, to: $1) }

    enum ThemeFileError: LocalizedError {
        case notATheme(String)
        var errorDescription: String? {
            switch self {
            case .notATheme(let file): return "“\(file)” isn't a Power BI theme file."
            }
        }
    }

    /// Decode a native Facet theme (the JSON form of `ThemeSpec`).
    nonisolated static func nativeImport(_ url: URL) throws -> ThemeSpec {
        let data = try Data(contentsOf: url)
        do {
            var theme = try JSONDecoder().decode(ThemeSpec.self, from: data)
            if theme.name.trimmingCharacters(in: .whitespaces).isEmpty { theme.name = url.deletingPathExtension().lastPathComponent }
            return theme
        } catch is DecodingError {
            throw ThemeFileError.notATheme(url.lastPathComponent)
        }
    }

    /// Encode a theme as native Facet JSON.
    nonisolated static func nativeExport(_ theme: ThemeSpec, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(theme).write(to: url, options: .atomic)
    }

    /// "Import theme…": pick a JSON file and make it the report's theme (undoable).
    static func runImport(_ store: DocumentStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a theme file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let theme = try (importer ?? { try nativeImport($0) })(url)
            store.mutate("Import Theme", invalidates: .layout) { $0.report.theme = theme }
            store.status = StatusMessage(kind: .success, text: "Applied the “\(theme.name)” theme.")
        } catch {
            store.status = StatusMessage(kind: .error, text: "Couldn't import “\(url.lastPathComponent)”. \(error.localizedDescription)")
        }
    }

    /// "Export theme…": save the report's current theme as JSON.
    static func runExport(_ store: DocumentStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(store.theme.name.isEmpty ? "Theme" : store.theme.name).json"
        panel.message = "Export the current theme."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (exporter ?? { try nativeExport($0, to: $1) })(store.theme, url)
            store.status = StatusMessage(kind: .success, text: "Exported the theme to “\(url.lastPathComponent)”.")
        } catch {
            store.status = StatusMessage(kind: .error, text: "Couldn't export the theme. \(error.localizedDescription)")
        }
    }
}

/// Page-size presets offered by the Theme pane and the page settings.
enum PageSizePreset: String, CaseIterable, Identifiable {
    case widescreen, standard, letter, tooltip, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .widescreen: return "16:9"
        case .standard: return "4:3"
        case .letter: return "Letter"
        case .tooltip: return "Tooltip"
        case .custom: return "Custom"
        }
    }
    var size: PageSize? {
        switch self {
        case .widescreen: return .widescreen
        case .standard: return .standard
        case .letter: return .letter
        case .tooltip: return .tooltip
        case .custom: return nil
        }
    }
    static func matching(_ size: PageSize) -> PageSizePreset {
        allCases.first { $0.size == size } ?? .custom
    }
}

enum ImagePicker {
    /// Ask for an image file and return its bytes.
    @MainActor
    static func choose() -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? Data(contentsOf: url)
    }
}
