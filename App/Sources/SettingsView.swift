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

    var body: some View {
        @Bindable var updates = updates
        NavigationStack {
            Form {
                updatesSection
                Section {
                    Toggle("Nightly Builds", isOn: $updates.nightly)
                } footer: {
                    Text("Nightly builds get YouTube fixes days before a stable release, but can have new bugs.")
                }
                accountsSection
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

    // MARK: - Updates

    private var updatesSection: some View {
        Section {
            LabeledContent("yt-dlp") {
                VStack(alignment: .trailing) {
                    Text(updates.runningVersion.map(UpdateManager.display) ?? "…").monospacedDigit()
                    Text(updates.isUsingUpdate ? "Updated" : "Built-in").font(.caption)
                }
            }

            switch updates.phase {
            case .idle, .upToDate, .failed:
                Button("Check for Updates") { Task { await updates.check() } }
            case .checking:
                HStack { ProgressView(); Text("Checking…").padding(.leading, 6) }
            case .available(let version):
                Button { Task { await updates.install(version) } } label: {
                    Label("Install \(UpdateManager.display(version))", systemImage: "arrow.down.circle")
                }
            case .installing(let version):
                HStack { ProgressView(); Text("Installing \(UpdateManager.display(version))…").padding(.leading, 6) }
            case .restartRequired(let version):
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(UpdateManager.display(version)) will be used after the app restarts.", systemImage: "arrow.clockwise.circle")
                    Button("Quit App Now") { exit(0) }
                        .font(.subheadline.weight(.semibold))
                }
            }

            if updates.isUsingUpdate || isRestartPending {
                Button("Revert to Built-in Version", role: .destructive) {
                    Task { await updates.revertToBundled() }
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            switch updates.phase {
            case .upToDate:
                Text("You have the latest version.")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            default:
                if let error = updates.loadError {
                    Text("An update failed to load and was disabled, so the built-in version is in use. (\(error))")
                        .foregroundStyle(.red)
                } else {
                    Text("YouTube changes often. Updating yt-dlp usually fixes downloads that stop working.")
                }
            }
        }
    }

    private var isRestartPending: Bool {
        if case .restartRequired = updates.phase { return true }
        return false
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
            Text("Signing in lets yt-dlp download videos that need an account. Swipe a site to sign out. YouTube may flag accounts used this way, so consider a spare account for YouTube.")
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
