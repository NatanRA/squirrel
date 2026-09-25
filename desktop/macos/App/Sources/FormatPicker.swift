import SwiftUI

struct FormatPicker: View {
    let info: VideoInfo
    let onPick: (FormatChoice) -> Void
    @Environment(\.dismiss) private var dismiss

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
                    Text([info.uploader, info.duration.map(Self.format)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding()

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
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 460, height: 440)
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

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
