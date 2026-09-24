import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(UpdateManager.self) private var updates
    @State private var showingSettings = false
    @State private var urlText = ""
    @State private var isFetching = false
    @State private var info: VideoInfo?
    @State private var alert: AlertMessage?
    @State private var previewURL: URL?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    inputRow
                    Button(action: fetch) {
                        HStack {
                            Spacer()
                            if isFetching {
                                ProgressView()
                                Text("Fetching…").padding(.leading, 6)
                            } else {
                                Label("Get Video", systemImage: "arrow.down.circle.fill")
                            }
                            Spacer()
                        }
                        .fontWeight(.semibold)
                    }
                    .disabled(isFetching || trimmedURL.isEmpty)
                } footer: {
                    if let error = store.startupError {
                        Text(error).foregroundStyle(.red)
                    } else if let latest = updates.availableVersion {
                        Button("yt-dlp \(UpdateManager.display(latest)) is available. Update in Settings.") { showingSettings = true }
                            .font(.footnote)
                    } else if let version = store.ytdlpVersion {
                        Text("yt-dlp \(UpdateManager.display(version)) · Files are saved to the yt-dlp folder in the Files app.")
                    } else {
                        Text("Starting yt-dlp…")
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
                                    Button(role: .destructive) { store.delete(item.id) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("yt-dlp")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .scrollDismissesKeyboard(.immediately)
            .sheet(item: $info) { info in
                FormatPicker(info: info) { choice in
                    store.download(info, choice: choice)
                    self.info = nil
                    urlText = ""
                }
            }
            .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
            .quickLookPreview($previewURL)
            .onOpenURL(perform: handleOpenURL)
        }
    }

    private var inputRow: some View {
        HStack {
            TextField("Paste a video link", text: $urlText)
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
            if !item.choice.isAudio {
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
        }
        if case .failed = item.state {
            Button { store.retry(item.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
        }
        if item.state == .cancelled {
            Button { store.retry(item.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
        }
        Button {
            UIPasteboard.general.string = item.sourceURL
        } label: {
            Label("Copy Link", systemImage: "link")
        }
        Button(role: .destructive) { store.delete(item.id) } label: { Label("Delete", systemImage: "trash") }
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetch() {
        let url = trimmedURL
        guard !url.isEmpty, !isFetching else { return }
        fieldFocused = false
        isFetching = true
        Task {
            defer { isFetching = false }
            do {
                info = try await store.fetchInfo(url)
            } catch {
                alert = AlertMessage(title: "Couldn't Get Video", message: error.localizedDescription)
            }
        }
    }

    private func open(_ item: DownloadItem) {
        switch item.state {
        case .finished:
            previewURL = store.fileURL(for: item)
        case .failed(let message):
            alert = AlertMessage(title: "Download Failed", message: message)
        default:
            break
        }
    }

    /// Supports `ytdlp://download?url=<link>` (handy from a Shortcuts share-sheet action).
    private func handleOpenURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let link = components.queryItems?.first(where: { $0.name == "url" })?.value
            ?? String(url.absoluteString.dropFirst("ytdlp://".count))
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
            caption("Merging audio and video…")
        case .finished:
            caption("\(item.choice.label) · \(item.choice.isAudio ? "Audio" : "Video")")
        case .cancelled:
            caption("Cancelled")
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
}

struct Thumbnail: View {
    let url: URL?
    let isAudio: Bool

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
        .frame(width: 80, height: 45)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
