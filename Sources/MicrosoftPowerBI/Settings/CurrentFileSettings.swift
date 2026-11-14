import SwiftUI
import FacetCore
import FacetDesign

/// The document whose window was active last: the one Settings ▸ Current File edits, and whose model
/// language formats values on screen.
@MainActor
final class ActiveDocument: ObservableObject {
    static let shared = ActiveDocument()
    private(set) weak var store: DocumentStore?

    func activate(_ store: DocumentStore) {
        guard self.store !== store else { return }
        objectWillChange.send()
        self.store = store
        // Visuals already drawn in another culture are queried and drawn again.
        if store.applyFormattingCulture() { store.refreshVisuals() }
    }

    func closed(_ store: DocumentStore) {
        guard self.store === store else { return }
        objectWillChange.send()
        self.store = nil
    }
}

extension DocumentStore {
    /// Values on screen are formatted in the active document's model language.
    @discardableResult
    func applyFormattingCulture() -> Bool {
        let culture = FormatCulture(identifier: doc.model.culture)
        guard ValueFormatter.culture != culture else { return false }
        ValueFormatter.culture = culture
        return true
    }

    /// After the engine loads: the active document (or the only one, before any window is active) sets the culture.
    func engineDidLoad() {
        let active = ActiveDocument.shared.store
        if active == nil || active === self { applyFormattingCulture() }
    }
}

/// Options stored on the document (Current File), each one undoable step.
@MainActor
enum CurrentFileOptions {
    static func setAutoDateTime(_ on: Bool, _ store: DocumentStore) {
        guard store.model.autoDateTime != on else { return }
        store.updateModel(on ? "Turn On Auto Date/Time" : "Turn Off Auto Date/Time") { $0.autoDateTime = on }
    }

    /// This file's "Autodetect new relationships after data is loaded", which then no longer follows Settings.
    static func setAutodetectRelationships(_ on: Bool, _ store: DocumentStore) {
        guard store.model.autodetectRelationships != on else { return }
        store.updateModel("Autodetect Relationships Option") { $0.autodetectRelationships = on }
    }

    static func setModelLanguage(_ culture: String, _ store: DocumentStore) {
        guard !culture.isEmpty, store.model.culture != culture else { return }
        store.updateModel("Model Language") { $0.culture = culture }
    }

    /// Query reduction; turning cross-highlighting off by default queries the visuals again.
    static func setQueryReduction(_ keyPath: WritableKeyPath<ReportSettings, Bool>, _ on: Bool, _ store: DocumentStore) {
        guard store.report.settings[keyPath: keyPath] != on else { return }
        let requery = keyPath == \ReportSettings.disableCrossHighlightByDefault
        store.mutate("Change Query Reduction", invalidates: requery ? .visuals(nil) : .layout) {
            $0.report.settings[keyPath: keyPath] = on
        }
    }
}

/// Settings ▸ Current File: the options saved in the active document.
struct CurrentFileSettings: View {
    @ObservedObject private var active = ActiveDocument.shared

    var body: some View {
        if let store = active.store {
            CurrentFileForm(store: store)
        } else {
            Form {
                Section {
                    Text("Open a document to change the options saved in it: auto date/time, relationship detection, model language and query reduction.")
                        .font(Design.Typeface.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct CurrentFileForm: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Document", value: store.displayName)
            } footer: {
                caption("These options are saved in the document, and each change can be undone there.")
            }
            Section("Data load") {
                Toggle(isOn: Binding(get: { store.model.autoDateTime }, set: { CurrentFileOptions.setAutoDateTime($0, store) })) {
                    labelled("Auto date/time", "Adds hidden date hierarchies under each date column of imported tables.")
                }
                Toggle(isOn: Binding(get: { DataLoadOptions.autodetectRelationships(for: store.doc) },
                                     set: { CurrentFileOptions.setAutodetectRelationships($0, store) })) {
                    labelled("Autodetect new relationships after data is loaded",
                             store.model.autodetectRelationships == nil ? "Follows Settings ▸ Data until changed here." : "Set for this file.")
                }
            }
            Section("Regional") {
                Picker("Model language", selection: Binding(get: { store.model.culture }, set: { CurrentFileOptions.setModelLanguage($0, store) })) {
                    CulturePicker.options
                    if !CulturePicker.cultures.contains(store.model.culture) { Text(CulturePicker.name(store.model.culture)).tag(store.model.culture) }
                }
                caption("How this file's numbers and dates are formatted, and the culture DAX's FORMAT and USERCULTURE() use.")
            }
            Section("Query reduction") {
                reduction("Turn off cross-highlighting by default", \.disableCrossHighlightByDefault)
                reduction("Add an Apply button to slicers", \.slicerApplyButtons)
                reduction("Add an Apply button to the Filters pane", \.filterPaneApplyButton)
            }
        }
        .formStyle(.grouped)
    }

    private func reduction(_ title: String, _ keyPath: WritableKeyPath<ReportSettings, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { store.report.settings[keyPath: keyPath] },
                                    set: { CurrentFileOptions.setQueryReduction(keyPath, $0, store) }))
    }

    private func labelled(_ title: String, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            caption(help)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
