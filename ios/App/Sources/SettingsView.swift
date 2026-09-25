import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(UpdateManager.self) private var updates
    @Environment(CookieStore.self) private var cookies
    @Environment(\.dismiss) private var dismiss

    @State private var signInSite: LoginSite?
    @State private var showingCustomSite = false
    @State private var customSiteText = ""
    @State private var showingImporter = false
    @State private var confirmRemoveAll = false
    @State private var alert: AlertMessage?
    @AppStorage(SaveSettings.videosToPhotosKey) private var videosToPhotos = true
    @AppStorage(SaveSettings.keepCopyKey) private var keepCopy = false

    var body: some View {
        NavigationStack {
            Form {
                savingSection
                updatesSection
                accountsSection
                Section {
                    NavigationLink("Advanced") { AdvancedSettingsView() }
                }
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await updates.refreshStatus() }
            .sheet(item: $signInSite) { site in
                SignInView(site: site) {
                    signInSite = nil
                    Task { await cookies.captureBrowserCookies() }
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.plainText, .data]) { result in
                guard case .success(let url) = result else { return }
                do {
                    try cookies.importFile(url)
                } catch {
                    alert = AlertMessage(title: "Couldn't Import Cookies", message: error.localizedDescription)
                }
            }
            .alert("Sign In to Another Site", isPresented: $showingCustomSite) {
                TextField("https://example.com/login", text: $customSiteText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                Button("Open") { openCustomSite() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Sign out of all sites?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
                Button("Sign Out of All", role: .destructive) { Task { await cookies.removeAll() } }
            }
            .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
        }
    }

    // MARK: - Saving

    private var savingSection: some View {
        Section {
            Toggle("Save Videos to Photos", isOn: $videosToPhotos)
            Toggle("Keep a Copy in the App", isOn: $keepCopy)
                .disabled(!videosToPhotos)
        } header: {
            Text("Saving")
        } footer: {
            Text("Audio stays in the app and in Files › Squirrel. So do videos Photos can't play, like 4K AV1 on older iPhones.")
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        Section {
            LabeledContent("yt-dlp", value: updates.runningVersion.map(UpdateManager.display) ?? "…")
                .monospacedDigit()
            UpdateStatusRow()
        } header: {
            Text("Updates")
        } footer: {
            if let error = updates.loadError {
                Text("An update failed to load, so the built-in version is in use. (\(error))")
                    .foregroundStyle(.red)
            } else {
                Text("yt-dlp updates itself automatically, which keeps downloads working when sites change.")
            }
        }
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        Section {
            ForEach(cookies.sites) { site in
                LabeledContent(site.domain) {
                    Text(site.imported ? "Imported" : "\(site.count) cookies")
                }
                .swipeActions {
                    Button("Sign Out", role: .destructive) { Task { await cookies.remove(site) } }
                }
            }
            Menu {
                ForEach(LoginSite.presets) { site in
                    Button(site.name) { signInSite = site }
                }
                Button("Other Site…") { showingCustomSite = true }
            } label: {
                Label("Sign In to a Site", systemImage: "person.crop.circle.badge.plus")
            }
            Button {
                showingImporter = true
            } label: {
                Label("Import cookies.txt", systemImage: "doc.badge.plus")
            }
            if !cookies.sites.isEmpty {
                Button("Sign Out of All Sites", role: .destructive) { confirmRemoveAll = true }
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Signing in lets Squirrel download videos that need an account. Swipe a site to sign out. YouTube may flag accounts used this way, so consider a spare account for YouTube.")
        }
    }

    // MARK: - About

    private static let sourceURL = URL(string: "https://github.com/FormulaLatest/squirrel")!

    private var aboutSection: some View {
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
            Text("Squirrel is free software under the GPL 3.0, built on yt-dlp (public domain), FFmpeg (LGPL 2.1) and Python. It isn't affiliated with YouTube or any site it downloads from.")
        }
    }

    private func openCustomSite() {
        var text = customSiteText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host != nil else { return }
        signInSite = LoginSite(name: url.host ?? "Sign In", url: url)
        customSiteText = ""
    }
}

/// One line describing what the automatic updater is doing.
private struct UpdateStatusRow: View {
    @Environment(UpdateManager.self) private var updates

    var body: some View {
        switch updates.phase {
        case .checking:
            progress("Checking for updates…")
        case .installing(let version):
            progress("Downloading \(UpdateManager.display(version))…")
        case .ready(let version):
            VStack(alignment: .leading, spacing: 6) {
                Text("\(UpdateManager.display(version)) will be used next time the app opens.")
                Button("Restart Now") { exit(0) }
                    .font(.subheadline.weight(.semibold))
            }
        case .idle, .failed:
            Text(lastChecked).foregroundStyle(.secondary)
        }
    }

    private var lastChecked: String {
        guard let date = updates.lastCheck else { return "Not checked yet" }
        return "Up to date · checked \(date.formatted(.relative(presentation: .named)))"
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// Manual controls for troubleshooting updates.
private struct AdvancedSettingsView: View {
    @Environment(UpdateManager.self) private var updates

    var body: some View {
        @Bindable var updates = updates
        Form {
            Section {
                LabeledContent("Running", value: updates.runningVersion.map(UpdateManager.display) ?? "…")
                LabeledContent("Built-in", value: updates.bundledVersion.map(UpdateManager.display) ?? "…")
                UpdateStatusRow()
                Button("Check Now") { Task { await updates.checkNow() } }
                    .disabled(isBusy)
            } header: {
                Text("yt-dlp")
            } footer: {
                if case .failed(let message) = updates.phase {
                    Text(message).foregroundStyle(.red)
                } else if updates.isUpToDate {
                    Text("You have the latest version.")
                }
            }

            Section {
                Toggle("Nightly Builds", isOn: $updates.nightly)
            } footer: {
                Text("Nightly builds get YouTube fixes days before a stable release, but can have new bugs.")
            }

            if updates.isUsingUpdate || isUpdatePending {
                Section {
                    Button("Revert to Built-in Version", role: .destructive) {
                        Task { await updates.revertToBundled() }
                    }
                } footer: {
                    Text("Removes the downloaded update if it causes problems. That version won't be installed again automatically.")
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
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
}
