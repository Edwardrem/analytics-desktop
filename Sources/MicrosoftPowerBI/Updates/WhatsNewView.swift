import SwiftUI
import AppKit
import FacetCore
import FacetDesign

/// What the What's New window shows.
enum WhatsNewContent: Equatable {
    case loading
    /// A new version, with the notes of it and of every version since the installed one.
    case offer(AvailableUpdate)
    /// The notes of versions just installed (or of the running version, from Help ▸ What's New).
    case installed([Release], SemanticVersion)
    case upToDate(SemanticVersion)
    /// GitHub has no releases of the app yet.
    case noReleases(SemanticVersion)
    case failed(String)
}

/// One window, reused: a newer check replaces what it shows.
@MainActor
enum WhatsNewWindow {
    private static var window: NSWindow?
    private static let model = WhatsNewModel()

    static func show(_ content: WhatsNewContent) {
        model.content = content
        model.error = nil
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "What's New in \(AppIdentity.name)"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 420, height: 360)
            w.contentView = NSHostingView(rootView: WhatsNewView(model: model))
            w.center()
            w.setFrameAutosaveName("WhatsNew")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

@MainActor
final class WhatsNewModel: ObservableObject {
    @Published var content: WhatsNewContent = .loading
    @Published var error: String?
    @Published var installing = false
}

struct WhatsNewView: View {
    @ObservedObject var model: WhatsNewModel
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        VStack(spacing: 0) {
            header.padding(Design.Space.xl)
            Hairline()
            ScrollView { notes.padding(Design.Space.xl) }
            if case .offer(let update) = model.content {
                Hairline()
                footer(update).padding(.horizontal, Design.Space.xl).padding(.vertical, Design.Space.l)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(Design.Palette.surface)
    }

    @ViewBuilder private var header: some View {
        HStack(alignment: .top, spacing: Design.Space.l) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text(title).font(Design.Typeface.title)
                Text(subtitle).font(Design.Typeface.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        switch model.content {
        case .loading: return "What's New"
        case .offer(let u): return "\(AppIdentity.name) \(u.version) is available"
        case .installed(_, let v): return "Welcome to \(AppIdentity.name) \(v)"
        case .upToDate: return "You're up to date"
        case .noReleases: return "No releases yet"
        case .failed: return "Couldn't check for updates"
        }
    }

    private var subtitle: String {
        switch model.content {
        case .loading: return "Fetching the release notes from GitHub…"
        case .offer(let u):
            let beta = u.release.isBeta ? " This is a beta release." : ""
            return "You have \(UpdateController.shared.installed). Here's what changed since then.\(beta)"
        case .installed(let r, _): return r.isEmpty ? "No release notes were published for this version." : "Here's what's new."
        case .upToDate(let v): return "\(AppIdentity.name) \(v) is the newest version."
        case .noReleases(let v): return "No version of \(AppIdentity.name) has been published on GitHub yet, so there's nothing newer than \(v)."
        case .failed(let message): return message
        }
    }

    @ViewBuilder private var notes: some View {
        switch model.content {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        case .offer(let u):
            releaseList(u.releases)
        case .installed(let releases, _):
            releaseList(releases)
        case .upToDate, .noReleases, .failed:
            EmptyView()
        }
    }

    private func releaseList(_ releases: [Release]) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xl) {
            ForEach(releases, id: \.tag) { r in
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                        Text(r.version.map { "Version \($0)" } ?? r.tag).font(Design.Typeface.headline)
                        if r.isBeta { Chip("Beta") }
                        Spacer(minLength: 0)
                        if let d = r.publishedAt {
                            Text(d.formatted(date: .abbreviated, time: .omitted)).font(Design.Typeface.caption).foregroundStyle(.secondary)
                        }
                    }
                    ReleaseNotesView(markdown: r.notes ?? "")
                    if let page = r.pageURL {
                        Link("View on GitHub", destination: page).font(Design.Typeface.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder private func footer(_ update: AvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            if !updates.canVerifyUpdates {
                Label(UpdateController.missingKeyNote, systemImage: "lock.trianglebadge.exclamationmark").font(Design.Typeface.caption)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(Design.Typeface.caption)
                    .foregroundStyle(Design.Palette.negative).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Design.Space.s) {
                progress
                Spacer(minLength: Design.Space.s)
                Button("Skip This Version") {
                    updates.skip(update)
                    WhatsNewWindow.close()
                }
                .disabled(model.installing)
                .help("Don't offer \(update.version.description) again. A later version will still be offered.")
                Button("Remind Me Later") {
                    updates.remindLater()
                    WhatsNewWindow.close()
                }
                .disabled(model.installing)
                .help("Offer this update again tomorrow.")
                if case .ready = updates.phase {
                    Button("Quit and Install") { NSApp.terminate(nil) }
                        .keyboardShortcut(.defaultAction)
                        .help("The update is downloaded and checked; it installs as \(AppIdentity.name) quits.")
                } else {
                    Button("Install and Relaunch") {
                        model.installing = true
                        model.error = nil
                        Task {
                            model.error = await updates.installAndRelaunch(update)
                            model.installing = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.installing || !updates.canVerifyUpdates)
                    .help("Downloads \(update.version.description), checks its signature, and replaces this copy of \(AppIdentity.name).")
                }
            }
        }
    }

    @ViewBuilder private var progress: some View {
        switch updates.phase {
        case .downloading(_, let received, let total):
            HStack(spacing: Design.Space.s) {
                ProgressView(value: Double(received), total: Double(max(total, 1))).frame(width: 120)
                Text(ByteCountFormatter.string(fromByteCount: received, countStyle: .file) + " of "
                     + ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                    .font(Design.Typeface.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .ready:
            Text("Ready: installs when \(AppIdentity.name) quits.").font(Design.Typeface.caption).foregroundStyle(.secondary)
        default:
            if model.installing { ProgressView().controlSize(.small) }
        }
    }
}
