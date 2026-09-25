import AppKit
import SwiftUI

struct SettingsView: View {
    /// Browsers the extension's engine link was installed for this launch.
    let browsers: [String]

    @Environment(AppSettings.self) private var settings
    @Environment(UpdateManager.self) private var updates
    @Environment(DownloadStore.self) private var store

    private static let sourceURL = URL(string: "https://github.com/FormulaLatest/ytdlp-mobile")!

    var body: some View {
        @Bindable var settings = settings
        @Bindable var updates = updates
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
            }

            Section {
                Picker("Use cookies from", selection: $settings.cookieBrowser) {
                    ForEach(CookieBrowser.allCases) { Text($0.name).tag($0) }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Lets Squirrel download videos that need you to be signed in, using the browser you're signed in with. macOS may ask for access. YouTube may flag accounts used this way.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Browsers", value: browsers.isEmpty ? "None found" : browsers.joined(separator: ", "))
                Link("Get the Extension", destination: Self.sourceURL.appending(path: "tree/main/extension"))
            } header: {
                Text("Browser Extension")
            } footer: {
                Text("The Squirrel extension for Chrome, Edge, Brave and Firefox uses this app to download. Keep the app installed; it doesn't need to be open.")
                    .foregroundStyle(.secondary)
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
            } header: {
                Text("Updates")
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

            Section {
                LabeledContent {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                } label: {
                    Text("Squirrel")
                    Text("Powered by yt-dlp and FFmpeg")
                }
                Link("Open-Source Licenses", destination: Self.sourceURL.appending(path: "blob/main/THIRD_PARTY_NOTICES.md"))
                Link("Source Code", destination: Self.sourceURL)
            } header: {
                Text("About")
            } footer: {
                Text("Squirrel is free, open-source software built on yt-dlp (public domain), FFmpeg (LGPL 2.1) and Python. It isn't affiliated with YouTube or any site it downloads from.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 620)
        .task { await updates.refreshStatus() }
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
