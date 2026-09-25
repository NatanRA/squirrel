import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var urlText = ""
    @State private var isFetching = false
    @State private var info: VideoInfo?
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

            Divider()
            footer
        }
        .onAppear {
            fieldFocused = true
            pasteLinkFromClipboard()
        }
        .sheet(item: $info) { info in
            FormatPicker(info: info) { choice in
                store.download(info, choice: choice)
                self.info = nil
                urlText = ""
            }
        }
        .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
    }

    private var footer: some View {
        HStack {
            if let error = store.startupError {
                Text(error).foregroundStyle(.red)
            } else if let version = store.ytdlpVersion {
                Text("yt-dlp \(UpdateManager.display(version)) · Saving to \(settings.downloadFolder.lastPathComponent)")
            } else {
                Text("Starting yt-dlp…")
            }
            Spacer()
            Button("Show Downloads") { NSWorkspace.shared.open(settings.downloadFolder) }
                .buttonStyle(.link)
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
                info = try await store.fetchInfo(url)
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
    let item: DownloadItem
    let live: LiveProgress?

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: item.thumbnail, isAudio: item.choice.isAudio)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                status
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
