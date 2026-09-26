import AppKit
import SafariServices
import SwiftUI

/// A browser on this Mac and whether Squirrel's extension is in it (Settings › Browsers).
struct BrowserStatus: Identifiable {
    enum Kind {
        /// Chrome, Brave, Edge, Arc and Vivaldi share Chrome's extension system
        case chromium(extensionsPage: String)
        case firefox
        case safari
    }

    let id: String  // bundle identifier
    let name: String
    let kind: Kind
    let appURL: URL
    /// Installed in at least one profile (enabled, for Safari)
    var extensionInstalled: Bool
}

enum Browsers {
    static let safariExtensionID = "app.squirrel.safari"

    /// A copy of the extension for "Load unpacked", refreshed from the app on every launch so an
    /// app update brings the extension's changes too.
    static let extensionFolder = AppPaths.support.appendingPathComponent("Browser Extension", isDirectory: true)

    private static let known: [(id: String, name: String, kind: BrowserStatus.Kind, data: String?)] = [
        ("com.brave.Browser", "Brave", .chromium(extensionsPage: "brave://extensions"), "BraveSoftware/Brave-Browser"),
        ("com.google.Chrome", "Google Chrome", .chromium(extensionsPage: "chrome://extensions"), "Google/Chrome"),
        ("com.microsoft.edgemac", "Microsoft Edge", .chromium(extensionsPage: "edge://extensions"), "Microsoft Edge"),
        ("company.thebrowser.Browser", "Arc", .chromium(extensionsPage: "chrome://extensions"), "Arc/User Data"),
        ("com.vivaldi.Vivaldi", "Vivaldi", .chromium(extensionsPage: "vivaldi://extensions"), "Vivaldi"),
        ("org.mozilla.firefox", "Firefox", .firefox, "Firefox"),
        ("com.apple.Safari", "Safari", .safari, nil),
    ]

    private static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    static func installed() async -> [BrowserStatus] {
        var result: [BrowserStatus] = []
        for browser in known {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.id) else { continue }
            let installed: Bool
            switch browser.kind {
            case .chromium:
                installed = chromiumHasExtension(dataFolder: browser.data!)
            case .firefox:
                installed = firefoxHasExtension()
            case .safari:
                installed = (try? await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: safariExtensionID))?.isEnabled ?? false
            }
            result.append(BrowserStatus(id: browser.id, name: browser.name, kind: browser.kind, appURL: appURL, extensionInstalled: installed))
        }
        return result
    }

    /// Chromium records its extensions in each profile's Preferences files.
    private static func chromiumHasExtension(dataFolder: String) -> Bool {
        let root = support.appendingPathComponent(dataFolder, isDirectory: true)
        let profiles = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let id = Data(NativeMessaging.chromeExtensionIDs[0].utf8)
        return profiles.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.contains { profile in
            ["Secure Preferences", "Preferences"].contains { file in
                (try? Data(contentsOf: root.appendingPathComponent(profile).appendingPathComponent(file)))?.range(of: id) != nil
            }
        }
    }

    private static func firefoxHasExtension() -> Bool {
        let profiles = support.appendingPathComponent("Firefox/Profiles", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? []
        let id = Data(NativeMessaging.firefoxExtensionID.utf8)
        return names.contains { name in
            (try? Data(contentsOf: profiles.appendingPathComponent(name).appendingPathComponent("extensions.json")))?.range(of: id) != nil
        }
    }

    /// Copies the extension bundled in the app (Resources/extension) to `extensionFolder`.
    static func refreshExtensionFolder() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("extension", isDirectory: true) else { return }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: extensionFolder)
            try fileManager.copyItem(at: bundled, to: extensionFolder)
            // Safari's version is built into the app; the README is for GitHub
            for extra in ["safari", "README.md"] {
                try? fileManager.removeItem(at: extensionFolder.appendingPathComponent(extra))
            }
        } catch {
            print("Couldn't copy the browser extension: \(error)")
        }
    }
}

// MARK: - Settings › Browsers

struct BrowserSettings: View {
    @State private var browsers: [BrowserStatus] = []
    @State private var copied: String?

    var body: some View {
        Form {
            Section {
                Text("Add Squirrel to your browser, then right-click any video, link or page and choose **Download with Squirrel**, or use the Squirrel button in the toolbar. Downloads go to your Squirrel folder.")
                    .foregroundStyle(.secondary)
            }
            if browsers.isEmpty {
                Section { Text("Looking for browsers…").foregroundStyle(.secondary) }
            }
            ForEach(browsers) { browser in
                Section {
                    setup(for: browser)
                } header: {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: browser.appURL.path))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(browser.name)
                        Spacer()
                        if browser.extensionInstalled {
                            Label(browser.id == "com.apple.Safari" ? "Turned on" : "Installed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.callout)
                        }
                    }
                }
            }
            Section {
                Text("Share › Squirrel also works from Safari and other apps, without an extension. And in any app, select text with a link, then right-click › Services › Download with Squirrel.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        // Pick up changes made in the browser while Settings was open
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        browsers = await Browsers.installed()
    }

    @ViewBuilder
    private func setup(for browser: BrowserStatus) -> some View {
        switch browser.kind {
        case .chromium(let page):
            if browser.extensionInstalled {
                Text("Right-click any video or link › Download with Squirrel. If Squirrel doesn't respond after an update, click the reload button on Squirrel in \(page).")
                    .foregroundStyle(.secondary)
            } else {
                steps([
                    "Open the extensions page and turn on **Developer mode**.",
                    "Click **Load unpacked** and choose the Squirrel extension folder. Or drag the folder onto the page.",
                    "Pin Squirrel from the puzzle-piece menu, if you'd like its button in the toolbar.",
                ])
            }
            HStack {
                Button("Open Extensions Page") { openExtensionsPage(page, in: browser) }
                Button("Show Extension Folder") { NSWorkspace.shared.activateFileViewerSelecting([Browsers.extensionFolder]) }
                if copied == browser.id {
                    Text("Address copied: paste it if the page didn't open.").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .firefox:
            if browser.extensionInstalled {
                Text("Right-click any video or link › Download with Squirrel.").foregroundStyle(.secondary)
            } else {
                Text("Firefox only keeps add-ons that Mozilla has signed, which Squirrel's isn't yet. To use it until Firefox quits:")
                    .foregroundStyle(.secondary)
                steps([
                    "Open **about:debugging** and choose **This Firefox**.",
                    "Click **Load Temporary Add-on** and choose **manifest.json** in the Squirrel extension folder.",
                ])
            }
            HStack {
                Button("Copy about:debugging") { copy("about:debugging#/runtime/this-firefox", for: browser) }
                Button("Show Extension Folder") { NSWorkspace.shared.activateFileViewerSelecting([Browsers.extensionFolder]) }
                if copied == browser.id {
                    Text("Copied: paste it into Firefox's address bar.").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .safari:
            if browser.extensionInstalled {
                Text("Click the Squirrel button in the toolbar, or right-click any video or link › Download with Squirrel.")
                    .foregroundStyle(.secondary)
            } else {
                steps([
                    "In Safari › Settings › Advanced, turn on **Show features for web developers**.",
                    "In the **Developer** tab, turn on **Allow unsigned extensions**. Safari turns this off each time it quits, because Squirrel isn't signed by an Apple developer.",
                    "In the **Extensions** tab, turn on **Squirrel**.",
                ])
            }
            Button("Open Safari Extensions") {
                SFSafariApplication.showPreferencesForExtension(withIdentifier: Browsers.safariExtensionID)
            }
        }
    }

    private func steps(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(.init(line))
                }
            }
        }
    }

    /// Browsers may refuse to open their own pages from outside, so the address is copied too.
    private func openExtensionsPage(_ page: String, in browser: BrowserStatus) {
        copy(page, for: browser)
        guard let url = URL(string: page) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: browser.appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    private func copy(_ text: String, for browser: BrowserStatus) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = browser.id
    }
}
