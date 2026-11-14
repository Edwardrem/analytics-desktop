import SwiftUI
import UniformTypeIdentifiers
import FacetCore
import FacetVisuals

/// Copying, exporting and printing what's on the canvas.
@MainActor
enum VisualExport {
    /// Data exporters by format ("csv", "xlsx", "json"), registered by the interop bridge.
    static var dataExporters: [String: (DataTable, [String], URL) throws -> Void] = [:]

    static func render(_ spec: VisualSpec, store: DocumentStore, scale: CGFloat = 2) -> NSImage? {
        let data = store.visualData[spec.id] ?? VisualData()
        let view = VisualView(spec: spec, data: data, context: store.context(for: spec, interactive: false))
            .frame(width: spec.frame.width, height: spec.frame.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.nsImage
    }

    static func copyImage(of spec: VisualSpec, store: DocumentStore) {
        guard let image = render(spec, store: store) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        store.status = StatusMessage(kind: .success, text: "Copied “\(spec.name)” as an image.")
    }

    static func exportData(of spec: VisualSpec, store: DocumentStore, format: String) {
        guard store.report.settings.allowExportData != "none" else {
            store.status = StatusMessage(kind: .warning, text: "Exporting data is turned off for this report.")
            return
        }
        guard let data = store.visualData[spec.id], !data.isEmpty else {
            store.status = StatusMessage(kind: .info, text: "This visual has no data to export.")
            return
        }
        guard let exporter = dataExporters[format] else {
            store.status = StatusMessage(kind: .warning, text: "The \(format.uppercased()) exporter isn't available.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .data]
        panel.nameFieldStringValue = "\(spec.name).\(format)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let rows = try write(data, with: exporter, to: url)
            store.status = StatusMessage(kind: .success, text: "Exported \(rows) rows to \(url.lastPathComponent).")
        } catch {
            store.status = StatusMessage(kind: .error, text: "Export failed. \(error.localizedDescription)")
        }
    }

    /// Writes a query result with its fields' captions as column names. Returns the rows written.
    static func write(_ data: VisualData, with exporter: (DataTable, [String], URL) throws -> Void, to url: URL) throws -> Int {
        var table = data.table
        for i in table.columns.indices { table.columns[i].name = data.fields[safe: i]??.caption ?? table.columns[i].name }
        try exporter(table, data.formats, url)
        return table.rowCount
    }

    static func insertImage(_ store: DocumentStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let size = NSImage(data: data)?.size ?? CGSize(width: 200, height: 200)
        let w = min(400, max(60, size.width)), h = w * (size.height / max(1, size.width))
        store.addVisual(.image) { v in
            v.imageData = data
            v.frame.width = w; v.frame.height = h
            v.name = url.deletingPathExtension().lastPathComponent
        }
    }

    /// Render one page (as readers see it: no selection chrome) for PDF, thumbnails and presenting.
    static func pageView(_ page: Page, store: DocumentStore) -> some View {
        ZStack(alignment: .topLeading) {
            store.theme.backgroundColor
            if let c = page.background.color { Color(hex: c).opacity(1 - page.background.transparency / 100) }
            if let d = page.background.imageData, let img = NSImage(data: d) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            }
            ForEach(page.visuals.filter { !$0.isHidden }.sorted { $0.zIndex < $1.zIndex }) { spec in
                VisualView(spec: spec, data: store.visualData[spec.id] ?? VisualData(), context: store.context(for: spec, interactive: false))
                    .frame(width: spec.frame.width, height: spec.frame.height)
                    .offset(x: spec.frame.x, y: spec.frame.y)
            }
        }
        .frame(width: page.size.width, height: page.size.height, alignment: .topLeading)
        .clipped()
    }

    /// Export all visible pages to a vector PDF, one PDF page per report page.
    static func exportPDF(_ store: DocumentStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = store.displayName + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let count = store.report.pages.filter { !$0.isHidden }.count
        store.status = StatusMessage(kind: .info, text: "Exporting \(count) page\(count == 1 ? "" : "s")…")
        Task {
            do {
                try await writePDF(store, to: url)
                store.status = StatusMessage(kind: .success, text: "Exported to \(url.lastPathComponent).")
            } catch {
                store.status = StatusMessage(kind: .error, text: "Export failed. \(error.localizedDescription)")
            }
        }
    }

    /// Draws every visible page, queried, into a PDF at `url`, then returns to the page that was showing.
    static func writePDF(_ store: DocumentStore, to url: URL) async throws {
        let pages = store.report.pages.filter { !$0.isHidden }
        let original = store.currentPageID
        var box = CGRect(x: 0, y: 0, width: 1280, height: 720)
        guard let consumer = CGDataConsumer(url: url as CFURL), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn't create “\(url.lastPathComponent)”."])
        }
        for page in pages {
            // Query each page before drawing it.
            store.goToPage(page.id, recordHistory: false)
            var waited = 0
            try? await Task.sleep(nanoseconds: 150_000_000)
            while !store.loadingVisuals.isEmpty, waited < 200 { try? await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
            let renderer = ImageRenderer(content: pageView(page, store: store))
            renderer.render { size, draw in
                var media = CGRect(origin: .zero, size: size)
                pdf.beginPage(mediaBox: &media)
                draw(pdf)
                pdf.endPage()
            }
        }
        pdf.closePDF()
        store.goToPage(original, recordHistory: false)
    }
}
