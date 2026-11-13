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
                if hasScript { return "Run the script to render the plot here. Script visuals use your local \(language) installation — enable them in Settings › Script visuals." }
                if hasFields { return "Write a \(language) script in the script editor. The fields in Values are passed to it as a data frame named dataset." }
                return "Script visuals run with your local \(language) installation. Enable script visuals in Settings, add fields to Values, then write a script that draws a plot."
            }()
            CmpPlaceholder(systemImage: "chevron.left.forwardslash.chevron.right", title: "\(language) visual", message: message, theme: env.theme)
        }
    }
}

// MARK: - Embedded content

struct CmpEmbedView: View {
    let env: CmpEnv

    /// Only http(s) URLs are ever loaded.
    static func url(from content: String) -> URL? {
        let s = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    private var info: (icon: String, title: String, hint: String) {
        switch env.spec.type {
        case .paginatedReport: return ("doc.richtext", "Paginated report", "Enter the report's URL to show a pixel-perfect paginated report here.")
        case .powerApps: return ("app.badge", "App", "Enter the web address of an app to run it inside this page.")
        case .powerAutomate: return ("bolt.horizontal", "Flow", "Enter a flow's web address, or assign a data-function action to show a run button.")
        default: return ("target", "Metrics", "Enter the web address of a scorecard to track goals here.")
        }
    }

    var body: some View {
        let info = self.info
        if let url = Self.url(from: env.spec.content) {
            if env.isInteractive {
                CmpWebContainer(url: url, theme: env.theme)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityLabel("\(info.title): \(url.host ?? url.absoluteString)")
            } else {
                CmpPlaceholder(systemImage: info.icon, title: url.host ?? info.title, message: url.absoluteString, theme: env.theme)
            }
        } else if env.spec.type == .powerAutomate, let action = env.spec.action, action.kind != .none {
            let label = env.f.string("text", "text", action.functionName.isEmpty ? "Run flow" : "Run \(action.functionName)")
            GeometryReader { geo in
                CmpButtonFace(env: env, resolver: CmpButtonResolver(env: env, defaultStyle: "filled"), title: label,
                              symbol: "bolt.fill", help: action.tooltip.isEmpty ? label : action.tooltip, accessibilityName: label) {
                    env.context.onAction(action)
                }
                .frame(width: min(geo.size.width, 220), height: min(geo.size.height, 40))
                .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            let bad = !env.spec.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            CmpPlaceholder(systemImage: info.icon, title: info.title,
                           message: bad ? "That address can't be opened. Use a full https:// URL." : info.hint, theme: env.theme)
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
