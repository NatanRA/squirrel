import SwiftUI

struct FormatPicker: View {
    let info: VideoInfo
    /// An earlier download of this video that's still where it was saved
    var downloaded: DownloadItem?
    let onPick: (FormatChoice) -> Void
    /// Opens the playlist the link also names (`info.playlistURL`)
    var onWholePlaylist: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SubtitleSettings.enabledKey) private var subtitles = false
    @AppStorage(SubtitleSettings.autoCaptionsKey) private var autoCaptions = false

    private var videoChoices: [FormatChoice] { info.choices.filter { !$0.isAudio } }
    private var audioChoices: [FormatChoice] { info.choices.filter(\.isAudio) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        AsyncImage(url: info.thumbnail) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ZStack {
                                Color.secondary.opacity(0.15)
                                Image(systemName: videoChoices.isEmpty ? "music.note" : "film")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 120, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(info.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(3)
                            Text([info.uploader, info.duration.map(formatDuration)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let subtitleNote {
                                Label(subtitleNote, systemImage: "captions.bubble")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let downloaded {
                                Label {
                                    Text("Downloaded \(downloaded.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                } icon: {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                if let url = info.playlistURL, let onWholePlaylist {
                    Section {
                        Button { onWholePlaylist(url) } label: {
                            Label("Whole Playlist…", systemImage: "list.bullet")
                        }
                    } footer: {
                        Text("Choose videos from the playlist this link is part of.")
                    }
                }

                if !videoChoices.isEmpty {
                    Section("Video") { ForEach(videoChoices, content: row) }
                }
                if !audioChoices.isEmpty {
                    Section("Audio Only") { ForEach(audioChoices, content: row) }
                }
            }
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// "With English subtitles": what Settings › Subtitles adds to a video download of this one
    private var subtitleNote: String? {
        guard subtitles, !videoChoices.isEmpty else { return nil }
        let names = SubtitleSettings.languages
            .filter { info.subtitleLanguages.contains($0) || autoCaptions && info.captionLanguages.contains($0) }
            .map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
        return names.isEmpty ? nil : "With \(names.formatted(.list(type: .and))) subtitles"
    }

    private func row(_ choice: FormatChoice) -> some View {
        Button { onPick(choice) } label: {
            HStack {
                Image(systemName: choice.isAudio ? "music.note" : "play.rectangle")
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading) {
                    Text(choice.label).foregroundStyle(Color.primary)
                    Text(choice.detail).font(.caption)
                        .foregroundStyle(choice.playable == false ? Color.orange : Color.secondary)
                }
                Spacer()
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
            }
        }
    }
}
