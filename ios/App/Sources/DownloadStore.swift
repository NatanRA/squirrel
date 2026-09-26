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
}

struct VideoInfo: Identifiable {
    let id: String
    let url: String
    let title: String
    let uploader: String?
    let duration: Double?
    let thumbnail: URL?
    let choices: [FormatChoice]
}

struct DownloadItem: Identifiable, Codable {
    enum State: Codable, Equatable {
        case queued, extracting, downloading, merging, finished, cancelled
        case failed(String)

        var isActive: Bool {
            switch self {
            case .queued, .extracting, .downloading, .merging: true
            default: false
            }
        }
    }

    let id: UUID
    var sourceURL: String
    var title: String
    var thumbnail: URL?
    var choice: FormatChoice
    var state: State
    /// Nil when the file was moved into Photos instead of kept in the app.
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
    private(set) var items: [DownloadItem] = []
    private(set) var live: [UUID: LiveProgress] = [:]
    private(set) var ytdlpVersion: String?
    private(set) var startupError: String?

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var continuations: [UUID: BackgroundContinuation] = [:]
    @ObservationIgnored private var folders: [Data: URL] = [:]

    init() {
        load()
        // Anything that was running when the app was killed can't be resumed.
        for index in items.indices where items[index].state.isActive {
            items[index].state = .failed("Interrupted")
        }
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

    func fetchInfo(_ url: String) async throws -> VideoInfo {
        let result = try await PythonRuntime.shared.call("extract", ["url": url])
        let choices = (result["choices"] as? [[String: Any]] ?? []).compactMap(FormatChoice.init)
        guard !choices.isEmpty else { throw BridgeError(message: "No downloadable formats found") }
        return VideoInfo(
            id: result["id"] as? String ?? UUID().uuidString,
            url: result["webpage_url"] as? String ?? url,
            title: result["title"] as? String ?? "Untitled",
            uploader: result["uploader"] as? String,
            duration: result["duration"] as? Double,
            thumbnail: (result["thumbnail"] as? String).flatMap(URL.init(string:)),
            choices: choices)
    }

    func download(_ info: VideoInfo, choice: FormatChoice) {
        let item = DownloadItem(
            id: UUID(), sourceURL: info.url, title: info.title, thumbnail: info.thumbnail,
            choice: choice, state: .queued, createdAt: .now)
        items.insert(item, at: 0)
        save()
        run(item.id)
        if !choice.isAudio, SaveSettings.videosToPhotos,
           PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            Task { _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        }
    }

    func retry(_ id: UUID) {
        update(id) { $0.state = .queued }
        run(id)
    }

    func cancel(_ id: UUID) {
        Task { _ = try? await PythonRuntime.shared.call("cancel", ["job_id": id.uuidString]) }
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

    /// Returns the new video's Photos identifier.
    ///
    /// Nonisolated: Photos runs the change block on its own queue, and a block
    /// inheriting this class's main-actor isolation would trap there.
    nonisolated private static func addToPhotos(_ url: URL, move: Bool) async throws -> String? {
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
        }
        return created.id
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

    // MARK: - Download pipeline

    private func run(_ id: UUID) {
        tasks[id] = Task { await perform(id) }
    }

    private func perform(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let jobID = id.uuidString
        let workDir = AppPaths.downloadWork.appendingPathComponent(jobID, isDirectory: true)

        // Keep going if the user leaves the app mid-download.
        let continuation = BackgroundContinuation(title: item.title) { [weak self] in self?.cancel(id) }
        continuations[id] = continuation

        update(id) { $0.state = .extracting }
        live[id] = LiveProgress(parts: item.choice.formatIDs.count)

        let poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let progress = try? await PythonRuntime.shared.call("progress", ["job_id": jobID]) else { continue }
                self?.apply(progress, to: id)
            }
        }

        do {
            let result = try await PythonRuntime.shared.call("download", [
                "url": item.sourceURL,
                "format_ids": item.choice.formatIDs,
                "out_dir": workDir.path,
                "job_id": jobID,
            ])
            poller.cancel()

            let files = (result["files"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            let title = (result["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? item.title
            guard !files.isEmpty else { throw BridgeError(message: "yt-dlp finished without producing a file") }

            // Merge or rewrap with FFmpeg into the container the format picker chose
            update(id) { $0.state = .merging }
            continuation.update(fraction: 1, subtitle: files.count > 1 ? "Merging audio and video…" : "Finishing…")
            let container = item.choice.ext.flatMap { Remuxer.canWrite($0) ? $0 : nil }
                ?? (item.choice.isAudio ? "m4a" : "mp4")
            let metadata = [
                "title": title,
                "artist": result["artist"] as? String ?? "",
                "date": result["date"] as? String ?? "",
                "comment": result["url"] as? String ?? item.sourceURL,
            ]
            var destination = Self.uniqueDestination(title: title, ext: container)
            do {
                try await Remuxer.remux(files, to: destination, metadata: metadata)
            } catch where files.count == 1 {
                // A format FFmpeg can't rewrap: keep the file exactly as downloaded
                destination = Self.uniqueDestination(
                    title: title, ext: Self.fileExtension(for: files[0], isAudio: item.choice.isAudio))
                try FileManager.default.moveItem(at: files[0], to: destination)
            }
            var fileName: String? = destination.lastPathComponent
            var savedToPhotos = false
            var photosAssetID: String?
            var photosNote: String?
            if !item.choice.isAudio && SaveSettings.videosToPhotos {
                if let reason = Self.photosIncompatibility(of: destination, choice: item.choice) {
                    photosNote = reason
                } else {
                    do {
                        let keepCopy = SaveSettings.keepCopy
                        photosAssetID = try await Self.addToPhotos(destination, move: !keepCopy)
                        savedToPhotos = true
                        if !keepCopy { fileName = nil }
                    } catch {
                        photosNote = error.localizedDescription  // the file stays in the app
                    }
                }
            }
            // Files that aren't going to Photos go to the folder chosen in Settings › Advanced, if any
            var folder: (bookmark: Data, name: String)?
            if !savedToPhotos, let chosen = SaveSettings.folder(for: item.choice.isAudio ? .audio : .video) {
                do {
                    guard let folderURL = self.folder(for: chosen.bookmark) else {
                        throw BridgeError(message: "The folder isn't available.")
                    }
                    fileName = try await Self.moveFile(destination, title: title, into: folderURL).lastPathComponent
                    folder = chosen
                } catch {
                    photosNote = "Couldn't save to \(chosen.name), so it's in Files › Squirrel. \(error.localizedDescription)"
                }
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
            update(id) { $0.state = .cancelled }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }

        poller.cancel()
        try? FileManager.default.removeItem(at: workDir)
        continuation.finish(success: items.first { $0.id == id }?.state == .finished)
        continuations[id] = nil
        live[id] = nil
        tasks[id] = nil
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
        continuations[id]?.update(fraction: current.fraction, subtitle: current.summary)
        if status == "downloading", items.first(where: { $0.id == id })?.state == .extracting {
            update(id) { $0.state = .downloading }
        }
    }

    // MARK: - Persistence

    private func update(_ id: UUID, _ body: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.library),
              let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = decoded
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

    nonisolated private static func uniqueDestination(
        title: String, ext: String, in directory: URL = AppPaths.documents
    ) -> URL {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        var base = title.components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        if base.isEmpty { base = "Download" }
        base = String(base.prefix(120))

        var url = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return url
    }

    // MARK: - Chosen folders
    //
    // Nonisolated so large files move off the main thread. File coordination lets
    // the app that owns the folder (or iCloud Drive) see the change.

    nonisolated private static func moveFile(_ file: URL, title: String, into folder: URL) async throws -> URL {
        let target = uniqueDestination(title: title, ext: file.pathExtension, in: folder)
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
            do { try FileManager.default.moveItem(at: file, to: url) } catch { moveError = error }
        }
        if let error = coordinationError ?? moveError { throw error }
        return target
    }

    nonisolated private static func removeFile(_ file: URL) async {
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: nil) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Carries a new asset's identifier out of a Photos change block, which runs
/// on Photos' queue and finishes before `performChanges` returns.
private final class CreatedAsset: @unchecked Sendable {
    var id: String?
}
