import Foundation
import Observation
import Photos

struct FormatChoice: Identifiable, Hashable, Codable {
    let id: String
    let label: String
    let detail: String
    let formatIDs: [String]
    let kind: String
    let ext: String?
    /// False when only third-party players like VLC can play it (e.g. AV1 without hardware decode).
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

    /// Stands in for a playlist item's choice until the bridge picks one from the video's formats.
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

/// A playlist's quality: the best version up to a height, or just the audio. The bridge turns it
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
    /// The playlist's own folder (or Photos album); nil for the videos of a single post
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
        /// Saved in a folder with this name inside the save folder, or a Photos album of this name
        var folder: String?
    }

    let id: UUID
    var sourceURL: String
    var title: String
    var thumbnail: URL?
    var choice: FormatChoice
    var state: State
    /// Nil when the file was moved into Photos instead of kept in the app. A path for a playlist
    /// in its own folder ("Playlist/Title.mp4").
    var fileName: String?
    var createdAt: Date
    var savedToPhotos: Bool?
    /// The video's Photos identifier, so Delete can remove it there too. Nil for
    /// videos saved before Squirrel kept track, which only leave the list.
    var photosAssetID: String?
    /// Set when the file went to a folder chosen in Settings › Advanced: `fileName` is then in
    /// this folder rather than the app's own.
    var folderBookmark: Data?
    var folderName: String?
    /// Why a download isn't where Settings says it goes: Photos, or a chosen folder.
    var photosNote: String?
    // Optional so libraries saved by older versions still load
    var key: String?
    /// A playlist item's quality; `choice` becomes the resolved choice once it downloads
    var target: DownloadTarget?
    var pick: Int?
    var playlist: PlaylistRef?

    /// Downloads added together from one playlist
    func isInBatch(with other: DownloadItem) -> Bool {
        playlist != nil && playlist?.id == other.playlist?.id && createdAt == other.createdAt
    }
}

/// "Saving" settings (see SettingsView), and the save locations in Settings › Advanced.
enum SaveSettings {
    static let videosToPhotosKey = "save.videosToPhotos"
    static let keepCopyKey = "save.keepCopy"

    static var videosToPhotos: Bool { UserDefaults.standard.object(forKey: videosToPhotosKey) as? Bool ?? true }
    static var keepCopy: Bool { UserDefaults.standard.bool(forKey: keepCopyKey) }

    enum Kind {
        case video, audio

        var folderKey: String { self == .video ? "save.videoFolder" : "save.audioFolder" }
        var folderNameKey: String { folderKey + "Name" }
    }

    /// A folder chosen in Settings › Advanced, which can be in another app or iCloud Drive.
    /// Nil means the app's own folder (Files › Squirrel).
    static func folder(for kind: Kind) -> (bookmark: Data, name: String)? {
        guard let bookmark = UserDefaults.standard.data(forKey: kind.folderKey) else { return nil }
        return (bookmark, UserDefaults.standard.string(forKey: kind.folderNameKey) ?? "Folder")
    }

    /// Remembers a folder from the folder picker, or goes back to the app's own with nil.
    static func setFolder(_ url: URL?, for kind: Kind) throws {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: kind.folderKey)
            UserDefaults.standard.removeObject(forKey: kind.folderNameKey)
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // A bookmark keeps access to the folder across launches
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
        UserDefaults.standard.set(bookmark, forKey: kind.folderKey)
        UserDefaults.standard.set(name, forKey: kind.folderNameKey)
    }
}

/// Live, non-persisted progress for an active download.
struct LiveProgress {
    var downloaded: Double = 0
    var total: Double = 0
    var speed: Double = 0
    var eta: Double?
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
    /// How many downloads run at once (Settings › Downloads); the rest wait their turn
    static let limitKey = "downloads.limit"
    static let defaultLimit = 2
    /// Settings › Downloads: each playlist in a folder (or Photos album) of its own
    static let playlistFolderKey = "playlists.ownFolder"

    private(set) var items: [DownloadItem] = []
    private(set) var live: [UUID: LiveProgress] = [:]
    private(set) var ytdlpVersion: String?
    private(set) var startupError: String?
    /// Waiting downloads don't start (after a relaunch, or once iOS stopped them in the
    /// background) until the user resumes
    private(set) var paused = false

    /// Started and not yet done
    @ObservationIgnored private var running: Set<UUID> = []
    /// Stopped because background time ran out: these wait again instead of showing as cancelled
    @ObservationIgnored private var interrupted: Set<UUID> = []
    /// Keeps the queue going after the user leaves the app
    @ObservationIgnored private var background: BackgroundContinuation?
    /// The downloads `background` covers, for "Downloading 3 of 12"
    @ObservationIgnored private var batch: Set<UUID> = []
    @ObservationIgnored private var folders: [Data: URL] = [:]
    /// Each playlist's Photos album, looked up (or made) once for all its videos
    @ObservationIgnored private var albums: [String: Task<String?, Never>] = [:]
    /// The Photos access question asked when downloads were added, in case it's still on screen
    @ObservationIgnored private var photosAccess: Task<PHAuthorizationStatus, Never>?

    var waitingCount: Int { items.count { $0.state == .queued } }

    private var limit: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.limitKey)
        return stored > 0 ? stored : Self.defaultLimit
    }

    init() {
        load()
        // Downloads that were running when the app was killed start over, but only once the user says so
        for index in items.indices where items[index].state.isActive {
            items[index].state = .queued
        }
        paused = waitingCount > 0
        try? FileManager.default.removeItem(at: AppPaths.downloadWork)
    }

    func startPython() async {
        do {
            ytdlpVersion = try await PythonRuntime.shared.start()
        } catch {
            startupError = error.localizedDescription
        }
    }

    func fileURL(for item: DownloadItem) -> URL? {
        guard let fileName = item.fileName else { return nil }
        guard let bookmark = item.folderBookmark else { return AppPaths.documents.appendingPathComponent(fileName) }
        return folder(for: bookmark)?.appendingPathComponent(fileName)
    }

    /// Resolves a chosen folder once and keeps it accessible while the app runs, so its
    /// files can be previewed, shared and deleted like the app's own.
    private func folder(for bookmark: Data) -> URL? {
        if let url = folders[bookmark] { return url }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()  // false for folders that don't need it
        folders[bookmark] = url
        return url
    }

    // MARK: - Actions

    /// A video with its download choices, or a playlist's items.
    func fetch(_ url: String) async throws -> FetchResult {
        let result = try await PythonRuntime.shared.call("extract", ["url": url, "playlists": true])
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
        guard !choices.isEmpty else { throw BridgeError(message: "No downloadable formats found") }
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
        if !choice.isAudio && SaveSettings.videosToPhotos {
            requestPhotosAccess(.addOnly)
        }
        resume()
    }

    /// Queues the chosen items of a playlist, each at `target` quality.
    func download(_ entries: [PlaylistEntry], from playlist: PlaylistInfo, target: DownloadTarget) {
        let ownFolder = UserDefaults.standard.object(forKey: Self.playlistFolderKey) as? Bool ?? true
        let folder = ownFolder ? playlist.folder : nil
        let added = Date.now
        let new = entries.map { entry in
            DownloadItem(
                id: UUID(), sourceURL: entry.url, title: entry.title, thumbnail: entry.thumbnail,
                choice: FormatChoice(target: target), state: .queued, createdAt: added,
                key: entry.key, target: target, pick: entry.pick,
                playlist: .init(id: playlist.id, title: playlist.title, index: entry.index,
                                count: playlist.entries.count, folder: folder))
        }
        items.insert(contentsOf: new, at: 0)
        save()
        if target.kind != "audio" && SaveSettings.videosToPhotos {
            // Asked once for the whole playlist; its album needs full access
            requestPhotosAccess(folder != nil ? .readWrite : .addOnly)
        }
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
            updateBackground()
        } else if running.contains(id) {
            Task { _ = try? await PythonRuntime.shared.call("cancel", ["job_id": id.uuidString]) }
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
        updateBackground()
    }

    /// Cancels every waiting download (the paused queue's "Cancel All").
    func cancelWaiting() {
        for index in items.indices where items[index].state == .queued && !running.contains(items[index].id) {
            items[index].state = .cancelled
        }
        paused = false
        save()
        updateBackground()
    }

    /// Starts waiting downloads again, and keeps them going when the user leaves the app.
    ///
    /// Only the user's own actions (download, retry, resume) come here: iOS only takes a
    /// request for background time while the app is open.
    func resume() {
        paused = false
        pump()
        guard !running.isEmpty else { return }
        // What was just added joins the progress iOS shows
        batch.formUnion(items.filter(\.state.isActive).map(\.id))
        if let background {
            background.renew()
            updateBackground()
        } else {
            let status = backgroundStatus()
            background = BackgroundContinuation(
                title: status.title, subtitle: status.subtitle, fraction: status.fraction
            ) { [weak self] in self?.backgroundTimeExpired() }
        }
    }

    /// Starts waiting downloads, oldest first, while fewer than the limit run.
    func pump() {
        while !paused, running.count < limit, let next = nextWaiting() {
            running.insert(next.id)
            Task {
                await perform(next.id)
                running.remove(next.id)
                interrupted.remove(next.id)
                pump()
            }
        }
        // Nothing left to run, or the rest is paused: the app can be suspended
        if running.isEmpty { endBackground() } else { updateBackground() }
    }

    private func nextWaiting() -> DownloadItem? {
        items.filter { $0.state == .queued && !running.contains($0.id) }.min(by: Self.inQueueOrder)
    }

    /// Oldest first, and a playlist's videos in its own order
    nonisolated private static func inQueueOrder(_ a: DownloadItem, _ b: DownloadItem) -> Bool {
        (a.createdAt, a.playlist?.index ?? 0) < (b.createdAt, b.playlist?.index ?? 0)
    }

    /// The finished download of the same video, if it's still where it was saved.
    func downloaded(key: String?, url: String) -> DownloadItem? {
        items.first { item in
            item.state == .finished && (key != nil && item.key == key || item.pick == nil && item.sourceURL == url)
                && isStillSaved(item)
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
            } else if item.state == .finished, isStillSaved(item) {
                downloaded.formUnion(ids)
            }
        }
        return (downloaded, active)
    }

    /// Videos in Photos count as still there: checking would take full Photos access.
    private func isStillSaved(_ item: DownloadItem) -> Bool {
        if item.savedToPhotos == true { return true }
        guard let url = fileURL(for: item) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Deletes the download everywhere Squirrel saved it: the file in the app and the video in Photos.
    func delete(_ id: UUID) async throws {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if let assetID = item.photosAssetID {
            do {
                try await Self.deleteFromPhotos(assetID)
            } catch let error as PHPhotosError where error.code == .userCancelled {
                return  // Declined iOS's confirmation, so keep everything
            }
        }
        if let url = fileURL(for: item) { await Self.removeFile(url) }
        removeFromList(id)
    }

    /// Clears the row and leaves any saved files where they are.
    func removeFromList(_ id: UUID) {
        if items.first(where: { $0.id == id })?.state.isActive == true { cancel(id) }
        items.removeAll { $0.id == id }
        save()
    }

    func saveToPhotos(_ item: DownloadItem) async throws {
        guard let url = fileURL(for: item) else { return }
        let assetID = try await Self.addToPhotos(url, move: false)
        update(item.id) {
            $0.savedToPhotos = true
            $0.photosAssetID = assetID
            $0.photosNote = nil
        }
        save()
    }

    // MARK: - Photos

    /// Asks for Photos access while the app is open, once for everything added together: adding
    /// videos, or full access to put a playlist in an album. Declining that still saves the videos.
    private func requestPhotosAccess(_ level: PHAccessLevel) {
        guard PHPhotoLibrary.authorizationStatus(for: level) == .notDetermined else { return }
        photosAccess = Task { await PHPhotoLibrary.requestAuthorization(for: level) }
    }

    /// The album a playlist's videos go in, found or made once per playlist so videos saved side
    /// by side don't each make one. Nil without full Photos access.
    private func photosAlbum(named title: String) async -> String? {
        _ = await photosAccess?.value  // the user may not have answered yet
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let lookup = albums[title] ?? Task { await Self.findOrCreateAlbum(title) }
        albums[title] = lookup
        let id = await lookup.value
        if id == nil { albums[title] = nil }  // try again with the next video
        return id
    }

    /// Returns the new video's Photos identifier.
    ///
    /// Nonisolated: Photos runs the change block on its own queue, and a block
    /// inheriting this class's main-actor isolation would trap there.
    nonisolated private static func addToPhotos(_ url: URL, move: Bool, album: String? = nil) async throws -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw BridgeError(message: "Photos access is off. Allow it in Settings › Apps › Squirrel › Photos.")
        }
        let created = CreatedAsset()
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = move  // no second copy of large files
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: options)
            created.id = request.placeholderForCreatedAsset?.localIdentifier
            if let album, let placeholder = request.placeholderForCreatedAsset,
               let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject {
                PHAssetCollectionChangeRequest(for: collection)?.addAssets([placeholder] as NSArray)
            }
        }
        return created.id
    }

    /// An album with this title, made if there isn't one. Needs full Photos access.
    nonisolated private static func findOrCreateAlbum(_ title: String) async -> String? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", title)
        if let album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject {
            return album.localIdentifier
        }
        let created = CreatedAsset()
        do {
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                created.id = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                    .placeholderForCreatedAssetCollection.localIdentifier
            }
            return created.id
        } catch {
            return nil
        }
    }

    /// iOS asks the user to confirm, and throws `PHPhotosError.userCancelled` if they don't.
    nonisolated private static func deleteFromPhotos(_ assetID: String) async throws {
        // Deleting needs read access, which saving didn't
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw BridgeError(message: "Squirrel needs Photos access to delete this video there. Allow it in Settings › Apps › Squirrel › Photos, or use Remove from List to keep the video.")
        }
        guard PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).count > 0 else {
            if status == .limited {
                throw BridgeError(message: "Squirrel can't see this video with limited Photos access. Choose Full Access in Settings › Apps › Squirrel › Photos, or delete it in Photos and use Remove from List.")
            }
            return  // Already deleted in Photos
        }
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil))
        }
    }

    /// Why Photos can't take this video, if it can't.
    private static func photosIncompatibility(of url: URL, choice: FormatChoice) -> String? {
        guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else {
            return "Photos can't store .\(url.pathExtension) videos."
        }
        if choice.playable == false {
            return "Photos can't play this format on this device."
        }
        return nil
    }

    // MARK: - Background

    /// Covers the whole queue while the user is away from the app. Ended once nothing is left
    /// to run; the next download, retry or resume starts another.
    private func updateBackground() {
        guard let background else { return }
        let status = backgroundStatus()
        background.update(title: status.title, subtitle: status.subtitle, fraction: status.fraction)
    }

    /// "Downloading 3 of 12" and the current video's title, or for a single download its title
    /// and progress.
    private func backgroundStatus() -> (title: String, subtitle: String, fraction: Double) {
        let covered = items.filter { batch.contains($0.id) && $0.state != .cancelled }
        let done = covered.count { !$0.state.isActive }
        let current = covered.filter { running.contains($0.id) }
        let progress = current.map { $0.state == .merging ? 1 : live[$0.id]?.fraction ?? 0 }.reduce(0, +)
        let fraction = covered.isEmpty ? 0 : (Double(done) + progress) / Double(covered.count)
        let first = current.min(by: Self.inQueueOrder)
        if covered.count == 1, let first {
            let subtitle = switch first.state {
            case .downloading: live[first.id]?.summary ?? "Downloading…"
            case .merging: "Finishing…"
            default: "Starting…"
            }
            return (first.title, subtitle, fraction)
        }
        return ("Downloading \(min(done + 1, covered.count)) of \(covered.count)", first?.title ?? "", fraction)
    }

    private func endBackground() {
        guard let background else { return }
        let failed = items.contains { item in
            guard batch.contains(item.id), case .failed = item.state else { return false }
            return true
        }
        background.finish(success: !paused && !failed)
        self.background = nil
        batch = []
    }

    /// iOS took the background time back, or the user stopped it from the system's progress UI:
    /// running downloads wait again, and start over once the user resumes.
    private func backgroundTimeExpired() {
        background = nil
        batch = []
        paused = true
        for id in running where items.first(where: { $0.id == id })?.state != .queued {
            interrupted.insert(id)
            Task { _ = try? await PythonRuntime.shared.call("cancel", ["job_id": id.uuidString]) }
        }
    }

    // MARK: - Download pipeline

    private func perform(_ id: UUID) async {
        // Skipped if it was cancelled, or the queue paused, before its turn came
        guard !paused, let item = items.first(where: { $0.id == id }), item.state == .queued else { return }
        let jobID = id.uuidString
        let workDir = AppPaths.downloadWork.appendingPathComponent(jobID, isDirectory: true)

        update(id) { $0.state = .extracting }
        live[id] = LiveProgress(parts: max(1, item.choice.formatIDs.count))
        updateBackground()

        let poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let progress = try? await PythonRuntime.shared.call("progress", ["job_id": jobID]) else { continue }
                self?.apply(progress, to: id)
            }
        }

        var args: [String: Any] = ["url": item.sourceURL, "out_dir": workDir.path, "job_id": jobID]
        if let target = item.target {
            // The bridge picks this video's choice for the playlist's quality
            args["target"] = target.arguments
        } else {
            args["format_ids"] = item.choice.formatIDs
        }
        if let pick = item.pick { args["playlist_index"] = pick }

        do {
            let result = try await PythonRuntime.shared.call("download", args)
            poller.cancel()

            let files = (result["files"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            let title = (result["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? item.title
            guard !files.isEmpty else { throw BridgeError(message: "yt-dlp finished without producing a file") }
            // What "Best" or "720p" came to for this video, which decides the container and Photos below
            let choice = (result["choice"] as? [String: Any]).flatMap(FormatChoice.init) ?? item.choice

            // Merge or rewrap with FFmpeg into the container the format picker chose
            update(id) {
                $0.state = .merging
                $0.choice = choice
                $0.key = result["key"] as? String ?? $0.key
            }
            updateBackground()
            let container = choice.ext.flatMap { Remuxer.canWrite($0) ? $0 : nil }
                ?? (choice.isAudio ? "m4a" : "mp4")
            let metadata = [
                "title": title,
                "artist": result["artist"] as? String ?? "",
                "date": result["date"] as? String ?? "",
                "comment": result["url"] as? String ?? item.sourceURL,
            ]
            var destination = Self.uniqueDestination(title: title, ext: container)
            do {
                try await Remuxer.remux(files, to: destination, metadata: metadata)
            } catch {
                try? FileManager.default.removeItem(at: destination)  // the name uniqueDestination reserved
                guard files.count == 1 else { throw error }
                // A format FFmpeg can't rewrap: keep the file exactly as downloaded
                destination = Self.uniqueDestination(
                    title: title, ext: Self.fileExtension(for: files[0], isAudio: choice.isAudio))
                try Self.move(files[0], ontoReserved: destination)
            }
            var fileName: String? = destination.lastPathComponent
            var savedToPhotos = false
            var photosAssetID: String?
            var photosNote: String?
            if !choice.isAudio && SaveSettings.videosToPhotos {
                if let reason = Self.photosIncompatibility(of: destination, choice: choice) {
                    photosNote = reason
                } else {
                    do {
                        let keepCopy = SaveSettings.keepCopy
                        // A playlist's videos go in an album named after it
                        var album: String?
                        if let name = item.playlist?.folder { album = await photosAlbum(named: name) }
                        do {
                            photosAssetID = try await Self.addToPhotos(destination, move: !keepCopy, album: album)
                        } catch where album != nil {
                            // Saved without the album rather than not at all
                            photosAssetID = try await Self.addToPhotos(destination, move: !keepCopy)
                        }
                        savedToPhotos = true
                        if !keepCopy { fileName = nil }
                    } catch {
                        photosNote = error.localizedDescription  // the file stays in the app
                    }
                }
            }
            // Files that aren't going to Photos go to the folder chosen in Settings › Advanced, if any,
            // and a playlist's into a folder of its own there or in Files › Squirrel
            var folder: (bookmark: Data, name: String)?
            if !savedToPhotos, let chosen = SaveSettings.folder(for: choice.isAudio ? .audio : .video) {
                do {
                    guard let folderURL = self.folder(for: chosen.bookmark) else {
                        throw BridgeError(message: "The folder isn't available.")
                    }
                    fileName = try await Self.moveFile(
                        destination, title: title, into: folderURL, subfolder: item.playlist?.folder)
                    folder = chosen
                } catch {
                    photosNote = "Couldn't save to \(chosen.name), so it's in Files › Squirrel. \(error.localizedDescription)"
                }
            } else if fileName != nil, let subfolder = item.playlist?.folder,
                      let path = try? await Self.moveFile(destination, title: title, into: AppPaths.documents, subfolder: subfolder) {
                fileName = path
            }
            update(id) {
                $0.state = .finished
                $0.title = title
                $0.fileName = fileName
                $0.folderBookmark = folder?.bookmark
                $0.folderName = folder?.name
                $0.savedToPhotos = savedToPhotos
                $0.photosAssetID = photosAssetID
                $0.photosNote = photosNote
            }
        } catch let error as BridgeError where error.cancelled {
            // Stopped with the background time rather than by the user: it waits for Resume
            update(id) { $0.state = interrupted.contains(id) ? .queued : .cancelled }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }

        poller.cancel()
        try? FileManager.default.removeItem(at: workDir)
        live[id] = nil
        save()
    }

    private func apply(_ progress: [String: Any], to id: UUID) {
        guard var current = live[id], let status = progress["status"] as? String else { return }
        current.downloaded = progress["downloaded"] as? Double ?? 0
        current.total = progress["total"] as? Double ?? 0
        current.speed = progress["speed"] as? Double ?? 0
        current.eta = progress["eta"] as? Double
        current.part = progress["part"] as? Int ?? current.part
        current.parts = progress["parts"] as? Int ?? current.parts
        live[id] = current
        if status == "downloading", items.first(where: { $0.id == id })?.state == .extracting {
            update(id) { $0.state = .downloading }
        }
        updateBackground()
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
            let backup = AppPaths.applicationSupport.appendingPathComponent("library.json.bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: AppPaths.library, to: backup)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.library.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: AppPaths.library, options: .atomic)
        } catch {
            print("Failed to save library: \(error)")
        }
    }

    /// The extension to save a single downloaded file under. Without ffmpeg
    /// nothing gets remuxed, so name files after what they actually contain.
    private static func fileExtension(for url: URL, isAudio: Bool) -> String {
        let ext = url.pathExtension.lowercased()
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 189), head.count >= 2 else { return ext }
        // HLS with MPEG-TS segments: raw TS even when yt-dlp names it .mp4
        if head.count == 189 && head[0] == 0x47 && head[188] == 0x47 { return "ts" }
        // Raw AAC (ADTS) audio, e.g. some HLS audio streams
        if head[0] == 0xFF && head[1] & 0xF6 == 0xF0 { return "aac" }
        // Audio-only MP4 is conventionally .m4a, which music apps recognise
        if isAudio && ext == "mp4" { return "m4a" }
        return ext
    }

    /// A new file name in `directory`, created empty straight away so downloads of same-titled
    /// videos finishing side by side can't pick the same one. The caller replaces or removes it.
    nonisolated private static func uniqueDestination(
        title: String, ext: String, in directory: URL = AppPaths.documents
    ) -> URL {
        let base = safeName(title, limit: 120, fallback: "Download")
        var counter = 1
        while true {
            let url = directory.appendingPathComponent(counter == 1 ? "\(base).\(ext)" : "\(base) (\(counter)).\(ext)")
            let file = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if file >= 0 {
                close(file)
                return url
            }
            // Only a taken name moves on; anything else is reported by the write that follows
            guard errno == EEXIST else { return url }
            counter += 1
        }
    }

    /// `title` as a file or folder name.
    nonisolated private static func safeName(_ title: String, limit: Int, fallback: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let name = title.components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return name.isEmpty ? fallback : String(name.prefix(limit))
    }

    /// Moves `file` over the empty file `uniqueDestination` reserved for it.
    nonisolated private static func move(_ file: URL, ontoReserved destination: URL) throws {
        // rename(2) replaces it in one step; across volumes, fall back to a copying move
        if rename(file.path, destination.path) == 0 { return }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
    }

    // MARK: - Chosen folders
    //
    // Nonisolated so large files move off the main thread. File coordination lets
    // the app that owns the folder (or iCloud Drive) see the change.

    /// Moves a finished file into `folder`, or a playlist's own folder inside it, and returns
    /// its path from `folder`.
    nonisolated private static func moveFile(
        _ file: URL, title: String, into folder: URL, subfolder: String? = nil
    ) async throws -> String {
        let subfolder = subfolder.map { safeName($0, limit: 80, fallback: "Playlist") }
        let directory = subfolder.map { folder.appendingPathComponent($0, isDirectory: true) } ?? folder
        if subfolder != nil {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let target = uniqueDestination(title: title, ext: file.pathExtension, in: directory)
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
            do { try move(file, ontoReserved: url) } catch { moveError = error }
        }
        if let error = coordinationError ?? moveError {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return [subfolder, target.lastPathComponent].compactMap { $0 }.joined(separator: "/")
    }

    nonisolated private static func removeFile(_ file: URL) async {
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: nil) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Carries a new asset's (or album's) identifier out of a Photos change block, which
/// runs on Photos' queue and finishes before `performChanges` returns.
private final class CreatedAsset: @unchecked Sendable {
    var id: String?
}
