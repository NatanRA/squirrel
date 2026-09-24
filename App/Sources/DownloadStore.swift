import Foundation
import Observation
import Photos
import UIKit

struct FormatChoice: Identifiable, Hashable, Codable {
    let id: String
    let label: String
    let detail: String
    let formatIDs: [String]
    let kind: String
    let ext: String?

    var isAudio: Bool { kind == "audio" }

    init?(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String, let formatIDs = dict["format_ids"] as? [String] else { return nil }
        self.id = id
        self.label = dict["label"] as? String ?? id
        self.detail = dict["detail"] as? String ?? ""
        self.formatIDs = formatIDs
        self.kind = dict["kind"] as? String ?? "video"
        self.ext = dict["ext"] as? String
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
    var fileName: String?
    var createdAt: Date
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
}

@MainActor
@Observable
final class DownloadStore {
    private(set) var items: [DownloadItem] = []
    private(set) var live: [UUID: LiveProgress] = [:]
    private(set) var ytdlpVersion: String?
    private(set) var startupError: String?

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static let libraryFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("library.json")
    private static let workRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("work", isDirectory: true)

    init() {
        load()
        // Anything that was running when the app was killed can't be resumed.
        for index in items.indices where items[index].state.isActive {
            items[index].state = .failed("Interrupted")
        }
        try? FileManager.default.removeItem(at: Self.workRoot)
    }

    func startPython() async {
        do {
            ytdlpVersion = try await PythonRuntime.shared.start()
        } catch {
            startupError = error.localizedDescription
        }
    }

    func fileURL(for item: DownloadItem) -> URL? {
        item.fileName.map { Self.documents.appendingPathComponent($0) }
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
    }

    func retry(_ id: UUID) {
        update(id) { $0.state = .queued }
        run(id)
    }

    func cancel(_ id: UUID) {
        Task { _ = try? await PythonRuntime.shared.call("cancel", ["job_id": id.uuidString]) }
    }

    func delete(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }) {
            if item.state.isActive { cancel(id) }
            if let url = fileURL(for: item) { try? FileManager.default.removeItem(at: url) }
        }
        items.removeAll { $0.id == id }
        save()
    }

    func saveToPhotos(_ item: DownloadItem) async throws {
        guard let url = fileURL(for: item) else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw BridgeError(message: "Allow photo library access in Settings to save videos.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    // MARK: - Download pipeline

    private func run(_ id: UUID) {
        tasks[id] = Task { await perform(id) }
    }

    private func perform(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let jobID = id.uuidString
        let workDir = Self.workRoot.appendingPathComponent(jobID, isDirectory: true)

        // Ask iOS for extra time if the user leaves the app mid-download.
        let background = UIApplication.shared.beginBackgroundTask(withName: "download \(jobID)")
        defer { UIApplication.shared.endBackgroundTask(background) }

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
            let title = result["title"] as? String ?? item.title
            let destination: URL
            if files.count >= 2 {
                update(id) { $0.state = .merging }
                destination = Self.uniqueDestination(title: title, ext: "mp4")
                let durations = (result["durations"] as? [Any] ?? []).compactMap { $0 as? Double }
                try await MediaMerger.merge(
                    video: files[0], audio: files[1], to: destination, knownDuration: durations.min())
            } else if let file = files.first {
                let ext = Self.isMPEGTS(file) ? "ts" : file.pathExtension
                destination = Self.uniqueDestination(title: title, ext: ext)
                try FileManager.default.moveItem(at: file, to: destination)
            } else {
                throw BridgeError(message: "yt-dlp finished without producing a file")
            }
            update(id) {
                $0.state = .finished
                $0.title = title
                $0.fileName = destination.lastPathComponent
            }
        } catch let error as BridgeError where error.cancelled {
            update(id) { $0.state = .cancelled }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }

        poller.cancel()
        try? FileManager.default.removeItem(at: workDir)
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
        guard let data = try? Data(contentsOf: Self.libraryFile),
              let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: Self.libraryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: Self.libraryFile, options: .atomic)
        } catch {
            print("Failed to save library: \(error)")
        }
    }

    /// Without ffmpeg, HLS streams with MPEG-TS segments are saved as raw TS
    /// even when yt-dlp names them .mp4; label them honestly.
    private static func isMPEGTS(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 189), data.count == 189 else { return false }
        return data[0] == 0x47 && data[188] == 0x47
    }

    private static func uniqueDestination(title: String, ext: String) -> URL {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        var base = title.components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        if base.isEmpty { base = "Download" }
        base = String(base.prefix(120))

        var url = documents.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = documents.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return url
    }
}
