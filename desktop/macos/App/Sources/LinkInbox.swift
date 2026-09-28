import AppKit
import Observation

/// Where links arrive from outside the window: squirrel:// URLs (sent by the Share menu and
/// Safari extensions) and the Services menu. The main window takes them and shows the formats,
/// reopening itself if it was closed.
@MainActor
@Observable
final class LinkInbox {
    static let shared = LinkInbox()

    /// Settings › General: fill in a copied link when the window or the menu bar item opens
    static let autoPasteKey = "paste.automatic"
    static var autoPaste: Bool { UserDefaults.standard.object(forKey: autoPasteKey) as? Bool ?? true }

    /// A link the main window hasn't picked up yet
    var pending: String?
    /// A playlist loaded elsewhere (the menu bar) for the main window to show, without loading it again
    var pendingPlaylist: PlaylistInfo?

    /// Set by views that have SwiftUI's openWindow action, so a link can reopen a closed window.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored var mainWindowIsOpen = false

    func receive(_ link: String) {
        pending = link
        NSApp.activate()
        if !mainWindowIsOpen { openMainWindow?() }
    }

    func show(_ playlist: PlaylistInfo) {
        pendingPlaylist = playlist
        NSApp.activate()
        if !mainWindowIsOpen { openMainWindow?() }
    }

    /// squirrel://download?url=<link>
    static func link(from url: URL) -> String? {
        guard url.scheme == "squirrel",
              let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "url" })?.value else { return nil }
        return firstLink(in: link)
    }

    /// The first web link in some text, e.g. "Look at this https://youtu.be/…"
    static func firstLink(in text: String) -> String? {
        text.firstMatch(of: /https?:\/\/\S+/).map { String($0.output) }
    }
}

/// App events SwiftUI doesn't cover: squirrel:// URLs, the Services menu and notifications.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        Notifier.shared.start()
        // At launch, not when the window opens: the browser extensions need these even if the
        // window never does (or opens later)
        Browsers.refreshExtensionFolder()
        NativeMessaging.register()
    }

    /// Unless Settings › General says to quit, keep running with the window closed: the menu bar
    /// item, the Share menu, Services and the browser extensions still use the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Background.keepRunning
    }

    /// Opening Squirrel again (Finder, Spotlight, Launchpad) while it runs in the background shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !LinkInbox.shared.mainWindowIsOpen { LinkInbox.shared.openMainWindow?() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let link = LinkInbox.link(from: url) { LinkInbox.shared.receive(link) }
        }
    }

    /// Services › Download with Squirrel, for selected text containing a link (NSServices in project.yml)
    @objc func downloadWithSquirrel(_ pasteboard: NSPasteboard, userData: String?,
                                    error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string) ?? ""
        guard let link = LinkInbox.firstLink(in: text) else {
            error.pointee = "There's no link in the selection." as NSString
            return
        }
        LinkInbox.shared.receive(link)
    }
}
