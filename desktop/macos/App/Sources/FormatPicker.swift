import AppKit
import SwiftUI

struct FormatPicker: View {
    let info: VideoInfo
    let onPick: (FormatChoice) -> Void
    /// Opens the playlist the link also names (`info.playlistURL`)
    var onWholePlaylist: ((String) -> Void)?
    @Environment(DownloadStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// An earlier download of this video whose file is still there
    @State private var downloaded: DownloadItem?

    private var videoChoices: [FormatChoice] { info.choices.filter { !$0.isAudio } }
    private var audioChoices: [FormatChoice] { info.choices.filter(\.isAudio) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Thumbnail(url: info.thumbnail, isAudio: videoChoices.isEmpty)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.title)
                        .font(.headline)
                        .lineLimit(3)
                    Text([info.uploader, info.duration.map(formatDuration)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding()

            if let downloaded, let file = downloaded.fileURL {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Downloaded \(downloaded.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        .buttonStyle(.link)
                }
                .font(.callout)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            List {
                if !videoChoices.isEmpty {
                    Section("Video") { ForEach(videoChoices, content: row) }
                }
                if !audioChoices.isEmpty {
                    Section("Audio Only") { ForEach(audioChoices, content: row) }
                }
            }
            .listStyle(.inset)

            HStack {
                if let url = info.playlistURL, let onWholePlaylist {
                    Button("Whole Playlist…") { onWholePlaylist(url) }
                        .help("Choose videos from the playlist this link is part of")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 460, height: 440)
        .onAppear { downloaded = store.downloaded(key: info.key, url: info.url) }
    }

    private func row(_ choice: FormatChoice) -> some View {
        Button { onPick(choice) } label: {
            HStack {
                Image(systemName: choice.isAudio ? "music.note" : "play.rectangle")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading) {
                    Text(choice.label)
                    Text(choice.detail).font(.caption)
                        .foregroundStyle(choice.playable == false ? Color.orange : Color.secondary)
                }
                Spacer()
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
