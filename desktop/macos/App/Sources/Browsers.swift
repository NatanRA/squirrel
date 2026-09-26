import AppKit
import SafariServices
import SwiftUI

/// A browser on this Mac and whether Squirrel's extension is in it (Settings › Browsers).
struct BrowserStatus: Identifiable {
    enum Kind: Equatable {
        /// Chrome, Brave, Edge, Opera, Arc, Vivaldi and others built on Chromium share Chrome's extensions
        case chromium(extensionsPage: String)
        /// Firefox, and browsers built on it like Zen
        case firefox
        case safari
    }

    let id: String  // bundle identifier
    let name: String
    let kind: Kind
    let appURL: URL
    /// Its folder in ~/Library/Application Support, with its profiles
    let dataFolder: URL?
    /// Installed in at least one profile (enabled, for Safari)
    var extensionInstalled = false
}

enum Browsers {
    static let safariExtensionID = "app.squirrel.safari"

    /// A copy of the extension for "Load unpacked", refreshed from the app on every launch so an
    /// app update brings the extension's changes too.
    static let extensionFolder = AppPaths.support.appendingPathComponent("Browser Extension", isDirectory: true)

    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    private struct Known {
        let name: String
        let kind: BrowserStatus.Kind
        /// In Application Support; nil when `dataFolder(…)` finds it
        var data: String?
    }

    private static let chrome = BrowserStatus.Kind.chromium(extensionsPage: "chrome://extensions")
    private static let opera = BrowserStatus.Kind.chromium(extensionsPage: "opera://extensions")
    private static let edge = BrowserStatus.Kind.chromium(extensionsPage: "edge://extensions")
    private static let brave = BrowserStatus.Kind.chromium(extensionsPage: "brave://extensions")
    private static let vivaldi = BrowserStatus.Kind.chromium(extensionsPage: "vivaldi://extensions")

    /// Browsers with their proper names, extension pages and folders. Others built on Chromium or
    /// Firefox are recognized anyway (see `engine(of:)`).
    private static let known: [String: Known] = [
        "com.google.Chrome": Known(name: "Google Chrome", kind: chrome, data: "Google/Chrome"),
        "com.google.Chrome.beta": Known(name: "Google Chrome Beta", kind: chrome, data: "Google/Chrome Beta"),
        "com.google.Chrome.dev": Known(name: "Google Chrome Dev", kind: chrome, data: "Google/Chrome Dev"),
        "com.google.Chrome.canary": Known(name: "Google Chrome Canary", kind: chrome, data: "Google/Chrome Canary"),
        "org.chromium.Chromium": Known(name: "Chromium", kind: chrome, data: "Chromium"),
        "com.brave.Browser": Known(name: "Brave", kind: brave, data: "BraveSoftware/Brave-Browser"),
        "com.brave.Browser.beta": Known(name: "Brave Beta", kind: brave, data: "BraveSoftware/Brave-Browser-Beta"),
        "com.brave.Browser.nightly": Known(name: "Brave Nightly", kind: brave, data: "BraveSoftware/Brave-Browser-Nightly"),
        "com.microsoft.edgemac": Known(name: "Microsoft Edge", kind: edge, data: "Microsoft Edge"),
        "com.microsoft.edgemac.Beta": Known(name: "Microsoft Edge Beta", kind: edge, data: "Microsoft Edge Beta"),
        "com.microsoft.edgemac.Dev": Known(name: "Microsoft Edge Dev", kind: edge, data: "Microsoft Edge Dev"),
        "com.microsoft.edgemac.Canary": Known(name: "Microsoft Edge Canary", kind: edge, data: "Microsoft Edge Canary"),
        "com.operasoftware.Opera": Known(name: "Opera", kind: opera, data: "com.operasoftware.Opera"),
        "com.operasoftware.OperaGX": Known(name: "Opera GX", kind: opera, data: "com.operasoftware.OperaGX"),
        "com.operasoftware.OperaAir": Known(name: "Opera Air", kind: opera, data: "com.operasoftware.OperaAir"),
        "com.vivaldi.Vivaldi": Known(name: "Vivaldi", kind: vivaldi, data: "Vivaldi"),
        "com.vivaldi.Vivaldi.snapshot": Known(name: "Vivaldi Snapshot", kind: vivaldi, data: "Vivaldi Snapshot"),
        "company.thebrowser.Browser": Known(name: "Arc", kind: chrome, data: "Arc/User Data"),
        "company.thebrowser.dia": Known(name: "Dia", kind: chrome),
        "ai.perplexity.comet": Known(name: "Comet", kind: chrome),
        "net.imput.helium": Known(name: "Helium", kind: chrome),
        "ru.yandex.desktop.yandex-browser": Known(name: "Yandex Browser", kind: .chromium(extensionsPage: "browser://extensions"), data: "Yandex/YandexBrowser"),
        "org.mozilla.firefox": Known(name: "Firefox", kind: .firefox, data: "Firefox"),
        "org.mozilla.firefoxdeveloperedition": Known(name: "Firefox Developer Edition", kind: .firefox, data: "Firefox"),
        "org.mozilla.nightly": Known(name: "Firefox Nightly", kind: .firefox, data: "Firefox"),
        "app.zen-browser.zen": Known(name: "Zen", kind: .firefox),
        "com.apple.Safari": Known(name: "Safari", kind: .safari),
    ]

    /// Browsers and Safari keep using wherever the app ran from, so it has to stay put: not the
    /// disk image, and not Downloads (where macOS runs a temporary copy).
    static var runsFromApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Every browser on this Mac that Squirrel's extension runs in: the apps macOS offers for web
    /// links plus the known ones, told apart by what they're built on.
    static func onThisMac() -> [BrowserStatus] {
        let workspace = NSWorkspace.shared
        let candidates = workspace.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            + known.keys.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        var seen = Set<String>()
        var browsers: [BrowserStatus] = []
        for appURL in candidates {
            guard let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier, !seen.contains(id),
                  let kind = known[id]?.kind ?? engine(of: bundle) else { continue }
            seen.insert(id)
            let name = known[id]?.name ?? appURL.deletingPathExtension().lastPathComponent
            browsers.append(BrowserStatus(id: id, name: name, kind: kind, appURL: appURL,
                                          dataFolder: dataFolder(id: id, name: name, kind: kind)))
        }
        return browsers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A browser not in `known`, by what it's built on. Apps that only open links (Electron apps,
    /// link pickers) and browsers on other engines are left out.
    private static func engine(of bundle: Bundle) -> BrowserStatus.Kind? {
        let fileManager = FileManager.default
        let contents = bundle.bundleURL.appendingPathComponent("Contents")
        guard opensWebPages(bundle),
              !fileManager.fileExists(atPath: contents.appendingPathComponent("Resources/app.asar").path) else { return nil }
        if fileManager.fileExists(atPath: contents.appendingPathComponent("MacOS/XUL").path) {
            return .firefox
        }
        let frameworks = (try? fileManager.contentsOfDirectory(atPath: contents.appendingPathComponent("Frameworks").path)) ?? []
        if frameworks.contains(where: { $0.hasSuffix(" Framework.framework") && $0 != "Electron Framework.framework" }) {
            return chrome
        }
        return nil
    }

    /// Browsers say they open HTML files; apps that just handle web links don't.
    private static func opensWebPages(_ bundle: Bundle) -> Bool {
        let types = bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        return types.contains { type in
            (type["LSItemContentTypes"] as? [String] ?? []).contains("public.html")
                || (type["CFBundleTypeExtensions"] as? [String] ?? []).contains("html")
        }
    }

    /// A browser's folder in Application Support. Chromium browsers keep a "Local State" file there
    /// and Firefox ones a "profiles.ini", which finds the folder of browsers not in `known`.
    private static func dataFolder(id: String, name: String, kind: BrowserStatus.Kind) -> URL? {
        let marker: String
        switch kind {
        case .chromium: marker = "Local State"
        case .firefox: marker = "profiles.ini"
        case .safari: return nil
        }
        let listed = known[id]?.data.map { support.appendingPathComponent($0, isDirectory: true) }
        let guesses = [id, name, "\(name)/User Data", name.lowercased()].map { support.appendingPathComponent($0, isDirectory: true) }
        return ([listed].compactMap { $0 } + guesses)
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
            ?? listed
    }

    /// The browsers on this Mac, with whether each has Squirrel's extension.
    static func installed() async -> [BrowserStatus] {
        var browsers = onThisMac()
        for index in browsers.indices {
            let browser = browsers[index]
            switch browser.kind {
            case .chromium:
                browsers[index].extensionInstalled = browser.dataFolder.map(chromiumHasExtension) ?? false
            case .firefox:
                browsers[index].extensionInstalled = browser.dataFolder.map(firefoxHasExtension) ?? false
            case .safari:
                browsers[index].extensionInstalled = (try? await SFSafariExtensionManager
                    .stateOfSafariExtension(withIdentifier: safariExtensionID))?.isEnabled ?? false
            }
        }
        return browsers
    }

    /// Chromium records its extensions in each profile's Preferences files. Profiles are "Default"
    /// and "Profile 2" and so on; Opera keeps its first one in the folder itself.
    private static func chromiumHasExtension(_ root: URL) -> Bool {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let profiles = [root] + folders.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.map { root.appendingPathComponent($0) }
        let id = Data(NativeMessaging.chromeExtensionIDs[0].utf8)
        return profiles.contains { profile in
            ["Secure Preferences", "Preferences"].contains { file in
                (try? Data(contentsOf: profile.appendingPathComponent(file)))?.range(of: id) != nil
            }
        }
    }

    private static func firefoxHasExtension(_ root: URL) -> Bool {
        let profiles = root.appendingPathComponent("Profiles", isDirectory: true)
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
            if !Browsers.runsFromApplications {
                Section {
                    Label("Move Squirrel to your Applications folder and open it from there first. Browsers, and Safari especially, can't use it where it is now.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
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
                            Label(browser.kind == .safari ? "Turned on" : "Installed", systemImage: "checkmark.circle.fill")
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
                Text("\(browser.name) only keeps add-ons that Mozilla has signed, which Squirrel's isn't yet. To use it until \(browser.name) quits:")
                    .foregroundStyle(.secondary)
                steps([
                    "Open **about:debugging** and choose **This \(browser.name)** (or This Firefox).",
                    "Click **Load Temporary Add-on** and choose **manifest.json** in the Squirrel extension folder.",
                ])
            }
            HStack {
                Button("Copy about:debugging") { copy("about:debugging#/runtime/this-firefox", for: browser) }
                Button("Show Extension Folder") { NSWorkspace.shared.activateFileViewerSelecting([Browsers.extensionFolder]) }
                if copied == browser.id {
                    Text("Copied: paste it into \(browser.name)'s address bar.").font(.caption).foregroundStyle(.secondary)
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
