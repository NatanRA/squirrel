import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(AppUpdateChecker.self) private var appUpdates
    @Environment(LinkInbox.self) private var inbox
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsView.tabKey) private var settingsTab = "general"
    @State private var urlText = ""
    @State private var isFetching = false
    @State private var fetched: FetchResult?
    @State private var alert: AlertMessage?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Paste a link", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($fieldFocused)
                    .onSubmit(fetch)
                Button(action: fetch) {
                    if isFetching {
                        ProgressView().controlSize(.small).frame(width: 70)
                    } else {
                        Text("Download").frame(width: 70)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isFetching || trimmedURL.isEmpty)
            }
            .padding(12)

            if let release = appUpdates.available {
                updateBanner(release)
            }

            if store.paused, store.waitingCount > 0 {
                pausedBanner
            }

            Divider()

            if store.items.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "tray.and.arrow.down",
                    description: Text("Paste a link from YouTube or any site yt-dlp supports."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.items) { item in
                        DownloadRow(item: item, live: store.live[item.id])
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { open(item) }
                            .contextMenu { menu(for: item) }
                    }
                }
                .listStyle(.inset)
            }

            if store.startupError != nil || store.items.isEmpty {
                Divider()
                footer
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { showSettings(tab: "browsers") } label: {
                    Label("Browsers", systemImage: "globe")
                }
                .help("Add Squirrel to your browsers")
                Button { NSWorkspace.shared.open(settings.downloadFolder) } label: {
                    Label("Show Downloads", systemImage: "folder")
                }
                .help("Show the Squirrel folder in Finder")
                Button { showSettings(tab: "general") } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .onAppear {
            fieldFocused = true
            inbox.mainWindowIsOpen = true
            inbox.openMainWindow = { openWindow(id: "main") }
            Background.updateDockIcon()
            if inbox.pending == nil { pasteLinkFromClipboard() }
        }
        .onDisappear {
            inbox.mainWindowIsOpen = false
            Background.updateDockIcon()
        }
        // Links from the Share menu, the Safari extension and the Services menu
        .onChange(of: inbox.pending, initial: true) { _, link in
            guard let link else { return }
            inbox.pending = nil
            fetched = nil
            urlText = link
            fetch()
        }
        // A playlist opened from the menu bar
        .onChange(of: inbox.pendingPlaylist?.id, initial: true) {
            guard let playlist = inbox.pendingPlaylist else { return }
            inbox.pendingPlaylist = nil
            fetched = .playlist(playlist)
        }
        .sheet(item: $fetched) { result in
            switch result {
            case .video(let info):
                FormatPicker(info: info) { choice in
                    store.download(info, choice: choice)
                    fetched = nil
                    urlText = ""
                } onWholePlaylist: { url in
                    fetched = nil
                    urlText = url
                    fetch()
                }
            case .playlist(let playlist):
                PlaylistSheet(playlist: playlist) { entries, target in
                    store.download(entries, from: playlist, target: target)
                    fetched = nil
                    urlText = ""
                }
            }
        }
        .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
    }

    private func showSettings(tab: String) {
        settingsTab = tab
        openSettings()
    }

    /// Downloads left waiting when Squirrel last quit don't start by surprise.
    private var pausedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            Text(store.waitingCount == 1 ? "1 download is waiting." : "\(store.waitingCount) downloads are waiting.")
                .fontWeight(.medium)
            Spacer()
            Button("Cancel All") { store.cancelWaiting() }
            Button("Resume") { store.resume() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// A newer Squirrel is out: Squirrel installs it itself and reopens.
    private func updateBanner(_ release: AppUpdateChecker.Release) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.app.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Squirrel \(release.version) is available.").fontWeight(.medium)
            Text("You have \(AppUpdateChecker.currentVersion).").foregroundStyle(.secondary)
            Spacer()
            Button("Not Now") { appUpdates.dismiss() }
            InstallUpdateButton(release: release)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack {
            if let error = store.startupError {
                Text(error).foregroundStyle(.red)
            }
            Spacer()
            if store.items.isEmpty {
                Button("Add Squirrel to your browser") { showSettings(tab: "browsers") }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func menu(for item: DownloadItem) -> some View {
        if item.state == .finished, item.fileURL != nil {
            Button("Open") { store.open(item) }
            Button("Show in Finder") { store.reveal(item) }
            Divider()
        }
        if item.state.isActive {
            Button("Cancel") { store.cancel(item.id) }
            if let playlist = item.playlist {
                Button("Cancel the Rest of “\(playlist.title)”") { store.cancelRest(of: item) }
            }
        }
        if case .failed(let message) = item.state {
            Button("Show Error") { alert = AlertMessage(title: "Download Failed", message: message) }
            Button("Retry") { store.retry(item.id) }
        }
        if item.state == .cancelled {
            Button("Retry") { store.retry(item.id) }
        }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.sourceURL, forType: .string)
        }
        Divider()
        Button("Remove from List") { store.remove(item.id) }
        if item.state == .finished, item.fileURL != nil {
            Button("Move to Trash") { store.remove(item.id, trash: true) }
        }
        if store.items.contains(where: { !$0.state.isActive }) {
            Button("Clear Finished") { store.clearFinished() }
        }
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A link on the clipboard is most likely what the user opened the app for.
    private func pasteLinkFromClipboard() {
        guard urlText.isEmpty, let text = NSPasteboard.general.string(forType: .string),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        urlText = url.absoluteString
    }

    private func fetch() {
        let url = trimmedURL
        guard !url.isEmpty, !isFetching else { return }
        isFetching = true
        Task {
            defer { isFetching = false }
            do {
                fetched = try await store.fetch(url)
            } catch {
                alert = AlertMessage(title: "Couldn’t Load Link", message: error.localizedDescription)
            }
        }
    }

    private func open(_ item: DownloadItem) {
        switch item.state {
        case .finished: store.open(item)
        case .failed(let message): alert = AlertMessage(title: "Download Failed", message: message)
        default: break
        }
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Rows

struct DownloadRow: View {
    @Environment(DownloadStore.self) private var store
    let item: DownloadItem
    let live: LiveProgress?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: item.thumbnail, isAudio: item.choice.isAudio)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                if let playlist = item.playlist {
                    caption("\(playlist.title) · \(playlist.index) of \(playlist.count)")
                        .lineLimit(1)
                }
                status
            }
            Spacer(minLength: 0)
            if hovering {
                hoverAction
            }
        }
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
    }

    /// Shown while the pointer is over the row
    @ViewBuilder
    private var hoverAction: some View {
        switch item.state {
        case .finished where item.fileURL != nil:
            rowButton("Show in Finder", systemImage: "magnifyingglass.circle.fill") { store.reveal(item) }
        case .queued, .extracting, .downloading, .merging:
            rowButton("Cancel", systemImage: "xmark.circle.fill") { store.cancel(item.id) }
        case .failed, .cancelled:
            rowButton("Retry", systemImage: "arrow.clockwise.circle.fill") { store.retry(item.id) }
        default:
            EmptyView()
        }
    }

    private func rowButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.title2)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .queued, .extracting:
            caption(item.state == .queued ? "Waiting…" : "Preparing…")
        case .downloading:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: live?.fraction ?? 0)
                    .opacity(live?.fraction == nil ? 0.4 : 1)
                caption(live?.summary ?? "Downloading…")
            }
        case .merging:
            caption((live?.parts ?? 1) > 1 ? "Merging audio and video…" : "Finishing…")
        case .finished:
            caption([item.choice.isAudio ? "Audio" : item.choice.label, fileType].joined(separator: " · "))
        case .cancelled:
            caption("Cancelled")
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private var fileType: String {
        item.fileURL?.pathExtension.uppercased() ?? (item.choice.isAudio ? "Audio" : "Video")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
}

struct Thumbnail: View {
    let url: URL?
    let isAudio: Bool
    var width: CGFloat = 96

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: isAudio ? "music.note" : "film")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: width < 80 ? 4 : 6))
    }
}
