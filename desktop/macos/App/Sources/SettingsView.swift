import AppKit
import SwiftUI

/// Settings (⌘,): tabs for downloads, browsers, accounts, updates and about.
struct SettingsView: View {
    /// Shared so other windows can open a particular tab
    static let tabKey = "settings.tab"
    @AppStorage(tabKey) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            BrowserSettings().tabItem { Label("Browsers", systemImage: "globe") }.tag("browsers")
            AccountSettings().tabItem { Label("Accounts", systemImage: "person.crop.circle") }.tag("accounts")
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }.tag("updates")
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 560, height: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadStore.self) private var store
    @AppStorage(DownloadStore.limitKey) private var limit = DownloadStore.defaultLimit
    @AppStorage(DownloadStore.playlistFolderKey) private var playlistFolders = true
    @AppStorage(MenuBar.shownKey) private var showMenuBar = true
    @AppStorage(Background.keepRunningKey) private var keepRunning = true
    @AppStorage(Notifier.enabledKey) private var notify = true

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Save to") {
                    HStack {
                        Text(settings.downloadFolder.path(percentEncoded: false)
                            .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Downloads at once", selection: $limit) {
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Save each playlist in its own folder", isOn: $playlistFolders)
                Toggle("Notify me when downloads finish", isOn: $notify)
            }
            Section {
                Toggle("Show Squirrel in the menu bar", isOn: $showMenuBar)
                Toggle("Keep running when the window is closed", isOn: $keepRunning)
            } footer: {
                Text(keepRunning && showMenuBar
                     ? "Download a link and follow progress from the menu bar. With the window closed, Squirrel stays up there and leaves the Dock; Quit is in its menu."
                     : "Download a link and follow progress from the menu bar, without opening this window.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: showMenuBar) { Background.updateDockIcon() }
        .onChange(of: limit) { store.pump() }
        .onChange(of: keepRunning) { Background.updateDockIcon() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.downloadFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadFolder = url
        }
    }
}

private struct AccountSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Use cookies from", selection: $settings.cookieBrowser) {
                    ForEach(CookieBrowser.allCases) { Text($0.name).tag($0) }
                }
            } footer: {
                Text("Lets Squirrel download videos that need you to be signed in, using the browser you're signed in with. macOS may ask for access. YouTube may flag accounts used this way.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    private static let sourceURL = URL(string: "https://github.com/NatanRA/squirrel")!

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                } label: {
                    Text("Squirrel")
                    Text("Powered by yt-dlp and FFmpeg")
                }
                Link("Open-Source Licenses", destination: Self.sourceURL.appending(path: "blob/main/THIRD_PARTY_NOTICES.md"))
                Link("Source Code", destination: Self.sourceURL)
            } footer: {
                Text("Squirrel is free software under the GPL 3.0, built on yt-dlp (public domain), FFmpeg (LGPL 2.1) and Python. It isn't affiliated with YouTube or any site it downloads from.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateSettings: View {
    @Environment(UpdateManager.self) private var updates
    @Environment(DownloadStore.self) private var store
    @Environment(AppUpdateChecker.self) private var appUpdates

    var body: some View {
        @Bindable var updates = updates
        Form {
            Section {
                LabeledContent("Squirrel", value: AppUpdateChecker.currentVersion)
                appUpdateStatus
                Button("Check for Updates") { Task { await appUpdates.checkNow() } }
                    .disabled(appUpdates.status == .checking)
            } footer: {
                Text("Squirrel also checks each time its window opens.").foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("yt-dlp", value: updates.runningVersion.map(UpdateManager.display) ?? "…")
                updateStatus
                Toggle("Nightly builds", isOn: $updates.nightly)
                HStack {
                    Button("Check Now") { Task { await updates.checkNow() } }
                        .disabled(isBusy)
                    if updates.isUsingUpdate || isUpdatePending {
                        Button("Revert to Built-in") { Task { await updates.revertToBundled() } }
                    }
                }
            } footer: {
                Group {
                    if let error = updates.loadError {
                        Text("An update failed to load, so the built-in version is in use. (\(error))").foregroundStyle(.red)
                    } else if case .failed(let message) = updates.phase {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("yt-dlp updates itself automatically, which keeps downloads working when sites change. Nightly builds get YouTube fixes sooner but can have new bugs.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await updates.refreshStatus() }
    }

    @ViewBuilder
    private var appUpdateStatus: some View {
        if let release = appUpdates.newer {
            HStack {
                Text("Squirrel \(release.version) is available.")
                Spacer()
                Link("What's New", destination: release.page)
                InstallUpdateButton(release: release)
            }
        } else {
            switch appUpdates.status {
            case .checking:
                progress("Checking for updates…")
            case .failed:
                Text("Couldn't reach GitHub. Check your internet connection and try again.").foregroundStyle(.red)
            case .idle, .upToDate:
                Text(appUpdates.lastCheck.map { "Up to date · checked \($0.formatted(.relative(presentation: .named)))" }
                     ?? "Not checked yet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updates.phase {
        case .checking:
            progress("Checking for updates…")
        case .installing(let version):
            progress("Downloading \(UpdateManager.display(version))…")
        case .ready(let version):
            HStack {
                Text("\(UpdateManager.display(version)) is ready.")
                Spacer()
                Button("Use Now") { Task { await updates.restartEngine() } }
                    .disabled(store.hasActiveDownloads)
                    .help(store.hasActiveDownloads ? "Wait for downloads to finish" : "Restart the download engine")
            }
        case .idle, .failed:
            Text(lastChecked).foregroundStyle(.secondary)
        }
    }

    private var lastChecked: String {
        guard let date = updates.lastCheck else { return "Not checked yet" }
        return "Up to date · checked \(date.formatted(.relative(presentation: .named)))"
    }

    private var isBusy: Bool {
        switch updates.phase {
        case .checking, .installing: true
        default: false
        }
    }

    private var isUpdatePending: Bool {
        if case .ready(let version) = updates.phase {
            return UpdateManager.normalized(version) != UpdateManager.normalized(updates.bundledVersion)
        }
        return false
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }
}
