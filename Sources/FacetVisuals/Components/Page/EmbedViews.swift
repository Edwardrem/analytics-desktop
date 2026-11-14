import SwiftUI
import AppKit
import WebKit
import FacetCore
import FacetDesign

// MARK: - Script visuals (Python / R)

/// Shows the plot the app rendered into `spec.imageData`; otherwise explains how script visuals work.
/// This module never runs scripts — the app does, and stores the output image in the spec.
struct CmpScriptVisualView: View {
    let env: CmpEnv

    var body: some View {
        let language = env.spec.type == .rVisual ? "R" : "Python"
        if let data = env.spec.imageData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(env.spec.altText.isEmpty ? "\(language) visual plot" : env.spec.altText)
                .accessibilityAddTraits(.isImage)
        } else {
            let hasScript = !env.spec.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasFields = !env.spec.fields(.values).isEmpty
            let message: String = {
                if hasScript { return "Run the script to render the plot here. Script visuals use your local \(language) installation — allow them in Settings › Scripting." }
                if hasFields { return "Write a \(language) script in the script editor. The fields in Values are passed to it as a data frame named dataset." }
                return "Script visuals run with your local \(language) installation. Enable script visuals in Settings, add fields to Values, then write a script that draws a plot."
            }()
            CmpPlaceholder(systemImage: "chevron.left.forwardslash.chevron.right", title: "\(language) visual", message: message, theme: env.theme)
        }
    }
}

// MARK: - Embedded content

/// The address an embedded visual shows or posts to.
public enum EmbedAddress {
    /// `content` as an https URL with a host; nil for anything else (http, file, javascript…).
    public static func httpsURL(from content: String) -> URL? {
        let s = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

/// Paginated reports, Power Apps and scorecards show their service page in a web view (readers sign
/// in to the service inside it); a Power Automate visual shows a button that sends the visual's
/// data to its flow. Without a source the visual says exactly what it needs, with a way to set it up.
struct CmpEmbedView: View {
    let env: CmpEnv

    /// Only https URLs are ever loaded or posted to.
    static func url(from content: String) -> URL? { EmbedAddress.httpsURL(from: content) }

    /// The icon, the name, and what the visual needs before it can show anything.
    static func info(for type: VisualType) -> (icon: String, title: String, need: String) {
        switch type {
        case .paginatedReport:
            return ("doc.richtext", "Paginated report",
                    "Connect a paginated report published to the Power BI service: enter its report ID or https:// address in Format › Source. Readers sign in to the service inside the visual.")
        case .powerApps:
            return ("app.badge", "Power Apps",
                    "Connect an app from Power Apps: enter its app ID or web link in Format › Source. Readers sign in to Power Apps inside the visual.")
        case .powerAutomate:
            return ("bolt.horizontal", "Power Automate",
                    "Connect a flow that starts with “When an HTTP request is received”: paste its HTTP POST URL in Format › Source. The button then sends this visual's data to the flow.")
        default:
            return ("target", "Metrics",
                    "Connect a scorecard from the Power BI service: enter its workspace and scorecard IDs, or its https:// address, in Format › Source.")
        }
    }

    var body: some View {
        let info = Self.info(for: env.spec.type)
        let content = env.spec.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = Self.url(from: content), env.spec.type == .powerAutomate {
            runButton(label: env.f.string("text", "text", "Run flow"), help: "Send this visual's data to the flow at \(url.host ?? "")",
                      enabled: env.context.onRunFlow != nil) { env.context.onRunFlow?(env.spec) }
        } else if let url = Self.url(from: content) {
            if env.isInteractive {
                CmpWebContainer(url: url, theme: env.theme)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityLabel("\(info.title): \(url.host ?? url.absoluteString)")
            } else {
                CmpPlaceholder(systemImage: info.icon, title: url.host ?? info.title, message: url.absoluteString, theme: env.theme)
            }
        } else if env.spec.type == .powerAutomate, content.isEmpty, let action = env.spec.action, action.kind != .none {
            let label = env.f.string("text", "text", action.functionName.isEmpty ? "Run flow" : "Run \(action.functionName)")
            runButton(label: label, help: action.tooltip.isEmpty ? label : action.tooltip, enabled: true) { env.context.onAction(action) }
        } else {
            let message = content.isEmpty ? info.need
                : "Only full https:// addresses are shown. Change the address in Format › Source."
            VStack(spacing: 8) {
                CmpPlaceholder(systemImage: info.icon, title: info.title, message: message, theme: env.theme)
                if env.isInteractive, let setUp = env.context.onSetUp {
                    Button("Set up…") { setUp(env.spec) }
                        .controlSize(.small)
                        .help("Choose what this \(info.title) visual shows")
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private func runButton(label: String, help: String, enabled: Bool, run: @escaping () -> Void) -> some View {
        GeometryReader { geo in
            CmpButtonFace(env: env, resolver: CmpButtonResolver(env: env, defaultStyle: "filled"), title: label,
                          symbol: "bolt.fill", isEnabled: enabled, help: help, accessibilityName: label, action: run)
                .frame(width: min(geo.size.width, 220), height: min(geo.size.height, 40))
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Web view with a quiet loading bar and a readable failure state.
struct CmpWebContainer: View {
    let url: URL
    let theme: ThemeSpec
    @State private var isLoading = true
    @State private var failure: String?

    var body: some View {
        ZStack(alignment: .top) {
            CmpWebView(url: url, isLoading: $isLoading, failure: $failure)
            if let failure {
                CmpPlaceholder(systemImage: "wifi.exclamationmark", title: "Couldn't load \(url.host ?? "page")", message: failure, theme: theme)
                    .background(theme.cardColor)
            } else if isLoading {
                ProgressView().progressViewStyle(.linear).controlSize(.small).tint(theme.accentColor)
            }
        }
    }
}

struct CmpWebView: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var failure: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.loaded = url
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loaded != url {
            context.coordinator.loaded = url
            view.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: CmpWebView
        var loaded: URL?
        init(_ parent: CmpWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true; parent.failure = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.isLoading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
        private func fail(_ error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            parent.isLoading = false
            parent.failure = error.localizedDescription
        }
    }
}
