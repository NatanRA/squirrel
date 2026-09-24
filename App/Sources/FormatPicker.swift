import SwiftUI

struct FormatPicker: View {
    let info: VideoInfo
    let onPick: (FormatChoice) -> Void
    @Environment(\.dismiss) private var dismiss

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
                            Color.secondary.opacity(0.15)
                        }
                        .frame(width: 120, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(info.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(3)
                            Text([info.uploader, info.duration.map(Self.format)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
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

    private func row(_ choice: FormatChoice) -> some View {
        Button { onPick(choice) } label: {
            HStack {
                Image(systemName: choice.isAudio ? "music.note" : "play.rectangle")
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading) {
                    Text(choice.label).foregroundStyle(Color.primary)
                    Text(choice.detail).font(.caption).foregroundStyle(Color.secondary)
                }
                Spacer()
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
            }
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
