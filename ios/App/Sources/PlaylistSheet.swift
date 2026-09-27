import SwiftUI

/// Choose which videos of a playlist, channel or multi-video post to download, and at what
/// quality. Videos already downloaded (or downloading) start unticked.
struct PlaylistSheet: View {
    let playlist: PlaylistInfo
    let onDownload: ([PlaylistEntry], DownloadTarget) -> Void
    @Environment(DownloadStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("playlists.quality") private var lastQuality = DownloadTarget.best.id
    @State private var quality = DownloadTarget.best
    @State private var selected: Set<Int> = []
    @State private var marks: [Int: Mark] = [:]
    /// Only this channel section (Videos, Shorts, Live); nil shows everything
    @State private var section: String?

    enum Mark {
        case downloaded, downloading, duplicate, unavailable, live

        var label: String {
            switch self {
            case .downloaded: "Downloaded"
            case .downloading: "In your downloads"
            case .duplicate: "Listed twice"
            case .unavailable: "Unavailable"
            case .live: "Live"
            }
        }

        /// Unavailable and live videos can't be downloaded at all
        var selectable: Bool { self != .unavailable && self != .live }
    }

    private var visible: [PlaylistEntry] {
        guard let section else { return playlist.entries }
        return playlist.entries.filter { $0.section == section }
    }

    private var chosen: [PlaylistEntry] { playlist.entries.filter { selected.contains($0.index) } }

    /// Everything shown that can be downloaded is ticked
    private var allSelected: Bool {
        visible.allSatisfy { marks[$0.index]?.selectable == false || selected.contains($0.index) }
    }

    var body: some View {
        NavigationStack {
            List {
                header
                Section {
                    // Remembered only when picked here, so a YouTube Music album doesn't make Audio stick
                    Picker("Quality", selection: Binding { quality } set: {
                        quality = $0
                        lastQuality = $0.id
                    }) {
                        ForEach(DownloadTarget.all) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if playlist.sections.count > 1 {
                        Picker("Show", selection: $section) {
                            Text("Everything").tag(String?.none)
                            ForEach(playlist.sections, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                } footer: {
                    Text("For each video, the best version up to this size, or just its audio.")
                }
                Section {
                    ForEach(visible, content: row)
                }
            }
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(allSelected ? "Select None" : "Select All") { select(!allSelected) }
                    Spacer()
                    Button(chosen.count == 1 ? "Download 1 Video" : "Download \(chosen.count) Videos") {
                        onDownload(chosen, quality)
                    }
                    .fontWeight(.semibold)
                    .disabled(chosen.isEmpty)
                }
            }
            .onAppear(perform: setUp)
        }
    }

    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Thumbnail(url: playlist.entries.first?.thumbnail, isAudio: false, width: 120)
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(3)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if playlist.truncated {
                        Text(playlist.count.map { "Showing the first \(playlist.entries.count) of \($0.formatted())." }
                             ?? "Showing the first \(playlist.entries.count).")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    private var summary: String {
        let total = playlist.entries.compactMap(\.duration).reduce(0, +)
        let count = playlist.entries.count == 1 ? "1 video" : "\(playlist.entries.count) videos"
        return [playlist.uploader, count, total > 0 ? formatDuration(total) : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func row(_ entry: PlaylistEntry) -> some View {
        let mark = marks[entry.index]
        let isSelected = selected.contains(entry.index)
        return Button { select(entry, !isSelected) } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Thumbnail(url: entry.thumbnail, isAudio: false, width: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                    Text([entry.duration.map(formatDuration), mark?.label].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(mark == nil ? Color.secondary : mark == .downloaded ? Color.green : Color.orange)
                }
            }
            .opacity(mark?.selectable == false ? 0.5 : 1)
        }
        .disabled(mark?.selectable == false)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ entry: PlaylistEntry, _ on: Bool) {
        if on { selected.insert(entry.index) } else { selected.remove(entry.index) }
    }

    /// Ticks or unticks what's shown, leaving out what can't be downloaded.
    private func select(_ on: Bool) {
        for entry in visible where marks[entry.index]?.selectable != false {
            select(entry, on)
        }
    }

    private func setUp() {
        quality = playlist.isMusic ? .audio : DownloadTarget.all.first { $0.id == lastQuality } ?? .best
        let library = store.library()
        var seen = Set<String>()
        for entry in playlist.entries {
            // Videos of one post share its link, so only their ids tell them apart
            let ids = entry.pick == nil ? [entry.key, entry.url].compactMap { $0 } : [entry.key].compactMap { $0 }
            let identity = entry.key ?? "\(entry.url)#\(entry.pick ?? 0)"
            let mark: Mark? =
                if entry.unavailable { .unavailable }
                else if entry.live { .live }
                else if !seen.insert(identity).inserted { .duplicate }
                else if ids.contains(where: library.downloaded.contains) { .downloaded }
                else if ids.contains(where: library.active.contains) { .downloading }
                else { nil }
            marks[entry.index] = mark
            if mark == nil { selected.insert(entry.index) }
        }
    }
}

/// "3:07", or "1:02:03" from an hour
func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
