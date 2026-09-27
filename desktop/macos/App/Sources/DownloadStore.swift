import AppKit
import Foundation
import Observation

struct FormatChoice: Identifiable, Hashable, Codable {
    let id: String
    let label: String
    let detail: String
    let formatIDs: [String]
    let kind: String
    let ext: String?
    /// False when only third-party players like VLC can play it.
    let playable: Bool?

    var isAudio: Bool { kind == "audio" }

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String, let formatIDs = dict["format_ids"] as? [String] else { return nil }
        self.id = id
        self.label = dict["label"] as? String ?? id
        self.detail = dict["detail"] as? String ?? ""
        self.formatIDs = formatIDs
        self.kind = dict["kind"] as? String ?? "video"
        self.ext = dict["ext"] as? String
        self.playable = dict["playable"] as? Bool
    }

    /// Stands in for a playlist item's choice until the engine picks one from the video's formats.
    init(target: DownloadTarget) {
        id = "target"
        label = target.label
        detail = ""
        formatIDs = []
        kind = target.kind
        ext = nil
        playable = nil
    }
}

/// A playlist's quality: the best version up to a height, or just the audio. The engine turns it
/// into one of each video's own choices when that video downloads.
struct DownloadTarget: Codable, Hashable, Identifiable {
    var kind: String
    var maxHeight: Int?

    static let best = DownloadTarget(kind: "video")
    static let audio = DownloadTarget(kind: "audio")
    static let all = [best, DownloadTarget(kind: "video", maxHeight: 1080), DownloadTarget(kind: "video", maxHeight: 720),
                      DownloadTarget(kind: "video", maxHeight: 480), audio]

    var id: String { kind == "audio" ? "audio" : maxHeight.map { "v\($0)" } ?? "best" }
    var label: String { kind == "audio" ? "Audio" : maxHeight.map { "\($0)p" } ?? "Best" }

    var arguments: [String: Any] {
        var args: [String: Any] = ["kind": kind]
        if let maxHeight { args["max_height"] = maxHeight }
        return args
    }
}

struct VideoInfo: Identifiable {
    let id: String
    let url: String
    let title: String
    let uploader: String?
    let duration: Double?
    let thumbnail: URL?
    let choices: [FormatChoice]
    /// Identifies the video across links (yt-dlp's archive id, "youtube dQw4w9WgXcQ")
    var key: String?
    /// The playlist a YouTube link also names, for "Whole Playlist"
    var playlistURL: String?
}

struct PlaylistEntry: Identifiable, Hashable {
    /// Position in the playlist, from 1
    let index: Int
    let key: String?
    let title: String
    let duration: Double?
    let thumbnail: URL?
    let url: String
    /// Set when the entry has no link of its own (e.g. the 2nd video of a post): which item of `url`
    let pick: Int?
    let section: String?
    let unavailable: Bool
    let live: Bool

    var id: Int { index }

    init(_ dict: [String: Any], index: Int, fallbackURL: String) {
        self.index = dict["index"] as? Int ?? index
        key = dict["key"] as? String
        title = dict["title"] as? String ?? "Item \(index)"
        duration = dict["duration"] as? Double
        thumbnail = (dict["thumbnail"] as? String).flatMap(URL.init(string:))
        url = dict["url"] as? String ?? fallbackURL
        pick = dict["pick"] as? Int
        section = dict["section"] as? String
        unavailable = dict["unavailable"] as? Bool ?? false
        live = dict["live"] as? Bool ?? false
    }
}

struct PlaylistInfo: Identifiable {
    let id: String
    let url: String
    let title: String
    let uploader: String?
    /// All items, which can be more than `entries` holds (see `truncated`); nil when the site doesn't say
    let count: Int?
    let truncated: Bool
    /// The playlist's own folder; nil for the videos of a single post
    let folder: String?
    let sections: [String]
    /// From YouTube Music, so audio is the likely choice
    let isMusic: Bool
    let entries: [PlaylistEntry]
}

/// What a pasted link turned out to be
enum FetchResult: Identifiable {
    case video(VideoInfo)
    case playlist(PlaylistInfo)

    var id: String {
        switch self {
        case .video(let info): "video:\(info.id)"
        case .playlist(let playlist): "playlist:\(playlist.id)"
        }
    }
}

struct DownloadItem: Identifiable, Codable {
    enum State: Codable, Equatable {
        case queued, extracting, downloading, merging, finished, cancelled
        case failed(String)

        /// Waiting or running
        var isActive: Bool {
            switch self {
            case .queued, .extracting, .downloading, .merging: true
            default: false
            }
        }
    }

    /// Which playlist a download came from, and where in it
    struct PlaylistRef: Codable, Hashable {
        var id: String
        var title: String
        var index: Int
        var count: Int
        /// Saved in a folder with this name inside the download folder
        var folder: String?
    }

    let id: UUID
    var sourceURL: String
    var title: String
    var thumbnail: URL?
    var choice: FormatChoice
    var state: State
    var filePath: String?
    var createdAt: Date
    // Optional so libraries saved by older versions still load
    var key: String?
    /// A playlist item's quality; `choice` becomes the resolved choice once it downloads
    var target: DownloadTarget?
    var pick: Int?
    var playlist: PlaylistRef?

    var fileURL: URL? { filePath.map { URL(fileURLWithPath: $0) } }

    /// Downloads added together from one playlist
    func isInBatch(with other: DownloadItem) -> Bool {
        playlist != nil && playlist?.id == other.playlist?.id && createdAt == other.createdAt
    }
}

/// Live, non-persisted progress for an active download.
struct LiveProgress {
    var downloaded: Double = 0
    var total: Double = 0
    var speed: Double = 0
    var part = 1
    var parts = 1

    var fraction: Double? {
        guard total > 0 else { return nil }
        // Spread multi-part downloads (video, then audio) across one bar.
        return (Double(part - 1) + min(downloaded / total, 1)) / Double(max(parts, 1))
    }

    /// "Video · 12.3 MB of 45 MB · 2.1 MB/s"
    var summary: String {
        var parts: [String] = []
        if self.parts > 1 {
            parts.append(part == 1 ? "Video" : "Audio")
        }
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(downloaded), countStyle: .file)
        if total > 0 {
            parts.append("\(bytes) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))")
        } else {
            parts.append(bytes)
        }
        if speed > 0 {
            parts.append("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s")
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
@Observable
final class DownloadStore {
    /// How many downloads run at once (Settings › General); the rest wait their turn
    static let limitKey = "downloads.limit"
    static let defaultLimit = 3
    /// Settings › General: each playlist in a folder of its own
    static let playlistFolderKey = "playlists.ownFolder"

    private(set) var items: [DownloadItem] = []
    private(set) var live: [UUID: LiveProgress] = [:]
    private(set) var ytdlpVersion: String?
    private(set) var startupError: String?
    /// Waiting downloads don't start (after a relaunch, until the user resumes)
    private(set) var paused = false
    /// Started and not yet done
    private var running: Set<UUID> = []

    var hasActiveDownloads: Bool { items.contains { $0.state.isActive } }
    var waitingCount: Int { items.count { $0.state == .queued } }

    /// Downloads running now, and how far along they are together (nil until sizes are known)
    var activeProgress: (count: Int, fraction: Double?) {
        let active = items.filter(\.state.isActive)
        let fractions = active.compactMap { live[$0.id]?.fraction }
        guard !active.isEmpty, !fractions.isEmpty else { return (active.count, nil) }
        return (active.count, fractions.reduce(0, +) / Double(active.count))
    }

    private var limit: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.limitKey)
        return stored > 0 ? stored : Self.defaultLimit
    }

    init() {
        load()
        // Downloads that were running when the app quit start over, but only once the user says so
        for index in items.indices where items[index].state.isActive {
            items[index].state = .queued
        }
        paused = waitingCount > 0
    }

    func start() async {
        refreshDock()  // downloads left waiting at the last quit
        do {
            ytdlpVersion = try await Engine.shared.call("start")["version"] as? String
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }

    // MARK: - Actions

    /// A video with its download choices, or a playlist's items.
    func fetch(_ url: String) async throws -> FetchResult {
        let result = try await Engine.shared.call("extract", ["url": url, "playlists": true])
        if result["type"] as? String == "playlist" {
            let pageURL = result["webpage_url"] as? String ?? url
            let entries = (result["entries"] as? [[String: Any]] ?? []).enumerated().map {
                PlaylistEntry($1, index: $0 + 1, fallbackURL: pageURL)
            }
            return .playlist(PlaylistInfo(
                id: result["id"] as? String ?? pageURL,
                url: pageURL,
                title: result["title"] as? String ?? "Playlist",
                uploader: result["uploader"] as? String,
                count: result["count"] as? Int,
                truncated: result["truncated"] as? Bool ?? false,
                folder: result["folder"] as? String,
                sections: result["sections"] as? [String] ?? [],
                isMusic: result["music"] as? Bool ?? false,
                entries: entries))
        }
        let choices = (result["choices"] as? [[String: Any]] ?? []).compactMap(FormatChoice.init)
        guard !choices.isEmpty else { throw EngineError(message: "No downloadable formats found") }
        return .video(VideoInfo(
            id: result["id"] as? String ?? UUID().uuidString,
            url: result["webpage_url"] as? String ?? url,
            title: result["title"] as? String ?? "Untitled",
            uploader: result["uploader"] as? String,
            duration: result["duration"] as? Double,
            thumbnail: (result["thumbnail"] as? String).flatMap(URL.init(string:)),
            choices: choices,
            key: result["key"] as? String,
            playlistURL: result["playlist_url"] as? String))
    }

    func download(_ info: VideoInfo, choice: FormatChoice) {
        let item = DownloadItem(
            id: UUID(), sourceURL: info.url, title: info.title, thumbnail: info.thumbnail,
            choice: choice, state: .queued, createdAt: .now, key: info.key)
        items.insert(item, at: 0)
        save()
        Notifier.shared.requestPermission()
        resume()
    }

    /// Queues the chosen items of a playlist, each at `target` quality.
    func download(_ entries: [PlaylistEntry], from playlist: PlaylistInfo, target: DownloadTarget) {
        let ownFolder = UserDefaults.standard.object(forKey: Self.playlistFolderKey) as? Bool ?? true
        let added = Date.now
        let new = entries.map { entry in
            DownloadItem(
                id: UUID(), sourceURL: entry.url, title: entry.title, thumbnail: entry.thumbnail,
                choice: FormatChoice(target: target), state: .queued, createdAt: added,
                key: entry.key, target: target, pick: entry.pick,
                playlist: .init(id: playlist.id, title: playlist.title, index: entry.index,
                                count: playlist.entries.count, folder: ownFolder ? playlist.folder : nil))
        }
        items.insert(contentsOf: new, at: 0)
        save()
        Notifier.shared.requestPermission()
        resume()
    }

    func retry(_ id: UUID) {
        update(id) { $0.state = .queued }
        save()
        resume()
    }

    func cancel(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.state == .queued {
            // Not started (perform skips it if it was about to)
            update(id) { $0.state = .cancelled }
            save()
            refreshDock()
        } else if running.contains(id) {
            Task { _ = try? await Engine.shared.call("cancel", ["job_id": id.uuidString]) }
        }
    }

    /// Cancels what's left of the playlist batch `item` belongs to.
    func cancelRest(of item: DownloadItem) {
        for index in items.indices where items[index].state.isActive && items[index].isInBatch(with: item) {
            if items[index].state == .queued {
                items[index].state = .cancelled  // saved once below, not per video
            } else {
                cancel(items[index].id)
            }
        }
        save()
        refreshDock()
    }

    /// Cancels every waiting download (the paused queue's "Cancel All").
    func cancelWaiting() {
        for index in items.indices where items[index].state == .queued && !running.contains(items[index].id) {
            items[index].state = .cancelled
        }
        paused = false
        save()
        refreshDock()
    }

    /// Starts waiting downloads again.
    func resume() {
        paused = false
        pump()
    }

    /// Starts waiting downloads, oldest first, while fewer than the limit run.
    func pump() {
        guard !paused else { return }
        while running.count < limit, let next = nextWaiting() {
            running.insert(next.id)
            Task {
                await perform(next.id)
                running.remove(next.id)
                finishedBatch(of: next.id)
                pump()
            }
        }
        refreshDock()
    }

    private func nextWaiting() -> DownloadItem? {
        items.filter { $0.state == .queued && !running.contains($0.id) }
            .min { ($0.createdAt, $0.playlist?.index ?? 0) < ($1.createdAt, $1.playlist?.index ?? 0) }
    }

    /// One notification for a whole playlist, once none of it is left to do
    private func finishedBatch(of id: UUID) {
        guard let item = items.first(where: { $0.id == id }), let playlist = item.playlist else { return }
        let batch = items.filter { $0.isInBatch(with: item) }
        guard !batch.contains(where: \.state.isActive) else { return }
        let done = batch.filter { $0.state == .finished }
        let failed = batch.count { if case .failed = $0.state { true } else { false } }
        Notifier.shared.playlistFinished(title: playlist.title, done: done.count, failed: failed, file: done.first?.filePath)
    }

    /// The finished download of the same video, if its file is still there.
    func downloaded(key: String?, url: String) -> DownloadItem? {
        items.first { item in
            item.state == .finished && (key != nil && item.key == key || item.pick == nil && item.sourceURL == url)
                && item.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
    }

    /// What the playlist picker needs to mark items: already downloaded, or waiting/running now.
    func library() -> (downloaded: Set<String>, active: Set<String>) {
        var downloaded = Set<String>(), active = Set<String>()
        for item in items {
            // Videos of one post share its link, so only their ids tell them apart
            let ids = [item.key, item.pick == nil ? item.sourceURL : nil].compactMap { $0 }
            if item.state.isActive {
                active.formUnion(ids)
            } else if item.state == .finished, let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) {
                downloaded.formUnion(ids)
            }
        }
        return (downloaded, active)
    }

    /// Removes the row; the file stays unless `trash` is set.
    func remove(_ id: UUID, trash: Bool = false) {
        if let item = items.first(where: { $0.id == id }) {
            if item.state.isActive { cancel(id) }
            if trash, let url = item.fileURL { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        }
        items.removeAll { $0.id == id }
        save()
        refreshDock()
    }

    func clearFinished() {
        items.removeAll { !$0.state.isActive }
        save()
    }

    func open(_ item: DownloadItem) {
        guard let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ item: DownloadItem) {
        guard let url = item.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Download pipeline

    private func perform(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }), item.state == .queued else { return }
        let jobID = id.uuidString
        update(id) { $0.state = .extracting }
        live[id] = LiveProgress(parts: max(1, item.choice.formatIDs.count))
        refreshDock()

        let poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let progress = try? await Engine.shared.call("progress", ["job_id": jobID]) else { continue }
                self?.apply(progress, to: id)
            }
        }

        var args: [String: Any] = ["url": item.sourceURL, "title": item.title, "job_id": jobID]
        if let target = item.target {
            // The engine picks this video's choice for the playlist's quality
            args["target"] = target.arguments
        } else {
            args["format_ids"] = item.choice.formatIDs
            args["ext"] = item.choice.ext ?? ""
            args["audio"] = item.choice.isAudio
        }
        if let pick = item.pick { args["playlist_index"] = pick }
        if let folder = item.playlist?.folder { args["subfolder"] = folder }

        do {
            // The engine downloads, merges and saves into the download folder
            let result = try await Engine.shared.call("download", args)
            update(id) {
                $0.state = .finished
                $0.title = result["title"] as? String ?? $0.title
                $0.filePath = result["path"] as? String
                $0.key = result["key"] as? String ?? $0.key
                if let choice = (result["choice"] as? [String: Any]).flatMap(FormatChoice.init) { $0.choice = choice }
            }
            if let finished = items.first(where: { $0.id == id }), finished.playlist == nil {
                Notifier.shared.finished(finished)
            }
        } catch let error as EngineError where error.cancelled {
            update(id) { $0.state = .cancelled }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
            if let failed = items.first(where: { $0.id == id }), failed.playlist == nil {
                Notifier.shared.failed(failed, error.localizedDescription)
            }
        }

        poller.cancel()
        live[id] = nil
        save()
        refreshDock()
    }

    private func refreshDock() {
        let progress = activeProgress
        DockProgress.shared.update(active: progress.count, fraction: progress.fraction)
    }

    private func apply(_ progress: [String: Any], to id: UUID) {
        guard var current = live[id], let status = progress["status"] as? String else { return }
        current.downloaded = progress["downloaded"] as? Double ?? current.downloaded
        current.total = progress["total"] as? Double ?? current.total
        current.speed = progress["speed"] as? Double ?? 0
        current.part = progress["part"] as? Int ?? current.part
        current.parts = progress["parts"] as? Int ?? current.parts
        live[id] = current
        refreshDock()
        guard let state = items.first(where: { $0.id == id })?.state, state.isActive else { return }
        if status == "downloading", state != .downloading {
            update(id) { $0.state = .downloading }
        } else if status == "merging", state != .merging {
            update(id) { $0.state = .merging }
        }
    }

    // MARK: - Persistence

    private func update(_ id: UUID, _ body: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.library) else { return }
        do {
            items = try JSONDecoder().decode([DownloadItem].self, from: data)
        } catch {
            // Keep a copy rather than let the next save replace the whole list with nothing
            print("Failed to load library: \(error)")
            let backup = AppPaths.support.appendingPathComponent("library.json.bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: AppPaths.library, to: backup)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: AppPaths.library, options: .atomic)
        } catch {
            print("Failed to save library: \(error)")
        }
    }
}
