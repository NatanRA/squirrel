import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(AppUpdateChecker.self) private var appUpdates
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false
    @State private var urlText = ""
    @State private var isFetching = false
    @State private var fetchTask: Task<Void, Never>?
    @State private var fetched: FetchResult?
    @State private var alert: AlertMessage?
    @State private var previewURL: URL?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if let release = appUpdates.available {
                    updateBanner(release)
                }
                if store.paused, store.waitingCount > 0 {
                    pausedBanner
                }
                Section {
                    inputRow
                    Button(action: fetch) {
                        HStack {
                            Spacer()
                            if isFetching {
                                ProgressView()
                                Text("Fetching…").padding(.leading, 6)
                            } else {
                                Label("Download", systemImage: "arrow.down.circle.fill")
                            }
                            Spacer()
                        }
                        .fontWeight(.semibold)
                    }
                    .disabled(isFetching || trimmedURL.isEmpty)
                } footer: {
                    if let error = store.startupError {
                        Text(error).foregroundStyle(.red)
                    }
                }

                if store.items.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "square.and.arrow.down",
                        description: Text("Paste a link from YouTube or any site yt-dlp supports."))
                    .listRowBackground(Color.clear)
                } else {
                    Section("Downloads") {
                        ForEach(store.items) { item in
                            DownloadRow(item: item, live: store.live[item.id])
                                .contentShape(Rectangle())
                                .onTapGesture { open(item) }
                                .contextMenu { menu(for: item) }
                                .swipeActions {
                                    // Not .destructive: iOS may ask first, and the row stays if the user says no
                                    if canDelete(item) {
                                        Button { delete(item) } label: { Label("Delete", systemImage: "trash") }
                                            .tint(.red)
                                    } else {
                                        Button { store.removeFromList(item.id) } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Squirrel")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .scrollDismissesKeyboard(.immediately)
            .sheet(item: $fetched) { result in
                switch result {
                case .video(let info):
                    FormatPicker(info: info, downloaded: store.downloaded(key: info.key, url: info.url)) { choice in
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
            .quickLookPreview($previewURL)
            .onOpenURL(perform: handleOpenURL)
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { autoPaste() }
            }
        }
    }

    /// Downloads left waiting when Squirrel was last closed (or that iOS stopped in the
    /// background) don't start by surprise.
    private var pausedBanner: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "pause.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(store.waitingCount == 1 ? "1 download is waiting." : "\(store.waitingCount) downloads are waiting.")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Cancel All") { store.cancelWaiting() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Button("Resume") { store.resume() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    /// A newer Squirrel is out. Sideloaded apps can't replace themselves, so Update opens the
    /// release page for AltStore, Sideloadly and the like.
    private func updateBanner(_ release: AppUpdateChecker.Release) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Squirrel \(release.version) is available")
                        .font(.subheadline.weight(.semibold))
                    Text("You have \(AppUpdateChecker.currentVersion).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link("Update", destination: release.page)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button { appUpdates.dismiss() } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Not Now")
            }
        }
    }

    private var inputRow: some View {
        HStack {
            TextField("Paste a link", text: $urlText)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($fieldFocused)
                .onSubmit(fetch)
            if !urlText.isEmpty {
                Button { urlText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in
                    urlText = text
                    fetch()
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
        }
    }

    @ViewBuilder
    private func menu(for item: DownloadItem) -> some View {
        if item.state == .finished, let url = store.fileURL(for: item) {
            ShareLink(item: url)
            if !item.choice.isAudio && item.savedToPhotos != true {
                Button {
                    Task {
                        do {
                            try await store.saveToPhotos(item)
                            alert = AlertMessage(title: "Saved to Photos", message: item.title)
                        } catch {
                            alert = AlertMessage(title: "Couldn't Save", message: error.localizedDescription)
                        }
                    }
                } label: {
                    Label("Save to Photos", systemImage: "photo.on.rectangle")
                }
            }
        }
        if item.state.isActive {
            Button { store.cancel(item.id) } label: { Label("Cancel", systemImage: "stop.circle") }
            if let playlist = item.playlist {
                Button { store.cancelRest(of: item) } label: {
                    Label("Cancel the Rest of “\(playlist.title)”", systemImage: "stop.circle")
                }
            }
        }
        if case .failed = item.state {
            Button { store.retry(item.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
        }
        if item.state == .cancelled {
            Button { store.retry(item.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
        }
        Button {
            UIPasteboard.general.string = item.sourceURL
            AutoPaste.markSeen()  // Don't paste it back on the next open
        } label: {
            Label("Copy Link", systemImage: "link")
        }
        if item.savedToPhotos == true || item.folderName != nil {
            Button { store.removeFromList(item.id) } label: {
                Label("Remove from List", systemImage: "minus.circle")
            }
        }
        if canDelete(item) {
            Button(role: .destructive) { delete(item) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// False for videos saved to Photos before Squirrel kept their Photos ID: those can only leave the list.
    private func canDelete(_ item: DownloadItem) -> Bool {
        item.savedToPhotos != true || item.photosAssetID != nil
    }

    private func delete(_ item: DownloadItem) {
        Task {
            do {
                try await store.delete(item.id)
            } catch {
                alert = AlertMessage(title: "Couldn’t Delete from Photos", message: error.localizedDescription)
            }
        }
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetch() {
        let url = trimmedURL
        guard !url.isEmpty else { return }
        fieldFocused = false
        // A newer link replaces one still loading, e.g. a squirrel:// link over an auto-pasted one
        fetchTask?.cancel()
        isFetching = true
        fetchTask = Task {
            do {
                let result = try await store.fetch(url)
                guard !Task.isCancelled else { return }
                fetched = result
            } catch {
                guard !Task.isCancelled else { return }
                alert = AlertMessage(title: "Couldn’t Load Link", message: error.localizedDescription)
            }
            isFetching = false
        }
    }

    /// Pastes and looks up a newly copied link when the app comes to the front (Settings › Pasting).
    private func autoPaste() {
        guard isIdle else { return }
        Task {
            guard let link = await AutoPaste.newLink(), isIdle else { return }
            urlText = link
            fetch()
        }
    }

    /// Nothing is in progress that an auto-pasted link would interrupt.
    private var isIdle: Bool {
        urlText.isEmpty && !isFetching && fetched == nil && !showingSettings && previewURL == nil && alert == nil
    }

    private func open(_ item: DownloadItem) {
        switch item.state {
        case .finished:
            if let url = store.fileURL(for: item) {
                previewURL = url
            } else if item.savedToPhotos == true, let photos = URL(string: "photos-redirect://") {
                UIApplication.shared.open(photos)
            }
        case .failed(let message):
            alert = AlertMessage(title: "Download Failed", message: message)
        default:
            break
        }
    }

    /// Supports `squirrel://download?url=<link>` (handy from a Shortcuts share-sheet action),
    /// and `ytdlp://` from before the rename.
    private func handleOpenURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let link = components.queryItems?.first(where: { $0.name == "url" })?.value
            ?? String(url.absoluteString.dropFirst("\(url.scheme ?? "squirrel")://".count))
        guard !link.isEmpty else { return }
        urlText = link
        fetch()
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Rows

struct DownloadRow: View {
    let item: DownloadItem
    let live: LiveProgress?

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: item.thumbnail, isAudio: item.choice.isAudio)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let playlist = item.playlist {
                    caption("\(playlist.title) · \(playlist.index) of \(playlist.count)")
                        .lineLimit(1)
                }
                status
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .queued, .extracting:
            caption(item.state == .queued ? "Waiting…" : "Preparing…")
        case .downloading:
            VStack(alignment: .leading, spacing: 3) {
                if let fraction = live?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView(value: 0).opacity(0.4)
                }
                caption(live?.summary ?? "Downloading…")
            }
        case .merging:
            caption(item.choice.convert == "mp3" ? "Converting to MP3…"
                    : (live?.parts ?? 1) > 1 ? "Merging audio and video…" : "Finishing…")
        case .finished:
            VStack(alignment: .leading, spacing: 2) {
                caption([item.choice.isAudio ? "Audio" : item.choice.label, location].joined(separator: " · "))
                if let note = item.photosNote {
                    Text(note).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
        case .cancelled:
            caption("Cancelled")
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private var location: String {
        switch (item.savedToPhotos == true, item.fileName != nil) {
        case (true, false): "Saved to Photos"
        case (true, true): "\(fileType) · In Photos"
        default: [fileType, item.folderName].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private var fileType: String {
        (item.fileName as NSString?)?.pathExtension.uppercased() ?? (item.choice.isAudio ? "Audio" : "Video")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
}

struct Thumbnail: View {
    let url: URL?
    let isAudio: Bool
    var width: CGFloat = 80

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
        .overlay(alignment: .bottomTrailing) {
            if isAudio, url != nil {
                Image(systemName: "music.note")
                    .font(.caption2.bold())
                    .padding(3)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(2)
            }
        }
    }
}
