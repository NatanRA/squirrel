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
    var filePath: String?
    var createdAt: Date

    var fileURL: URL? { filePath.map { URL(fileURLWithPath: $0) } }
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
    private(set) var items: [DownloadItem] = []
    private(set) var live: [UUID: LiveProgress] = [:]
    private(set) var ytdlpVersion: String?
    private(set) var startupError: String?

    var hasActiveDownloads: Bool { items.contains { $0.state.isActive } }

    init() {
        load()
        // Anything that was running when the app quit can't be resumed.
        for index in items.indices where items[index].state.isActive {
            items[index].state = .failed("Interrupted")
        }
    }

    func start() async {
        do {
            ytdlpVersion = try await Engine.shared.call("start")["version"] as? String
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }

    // MARK: - Actions

    func fetchInfo(_ url: String) async throws -> VideoInfo {
        let result = try await Engine.shared.call("extract", ["url": url])
        let choices = (result["choices"] as? [[String: Any]] ?? []).compactMap(FormatChoice.init)
        guard !choices.isEmpty else { throw EngineError(message: "No downloadable formats found") }
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
        Task { await perform(item.id) }
    }

    func retry(_ id: UUID) {
        update(id) { $0.state = .queued }
        Task { await perform(id) }
    }

    func cancel(_ id: UUID) {
        Task { _ = try? await Engine.shared.call("cancel", ["job_id": id.uuidString]) }
    }

    /// Removes the row; the file stays unless `trash` is set.
    func remove(_ id: UUID, trash: Bool = false) {
        if let item = items.first(where: { $0.id == id }) {
            if item.state.isActive { cancel(id) }
            if trash, let url = item.fileURL { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        }
        items.removeAll { $0.id == id }
        save()
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
        guard let item = items.first(where: { $0.id == id }) else { return }
        let jobID = id.uuidString
        update(id) { $0.state = .extracting }
        live[id] = LiveProgress(parts: item.choice.formatIDs.count)

        let poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let progress = try? await Engine.shared.call("progress", ["job_id": jobID]) else { continue }
                self?.apply(progress, to: id)
            }
        }

        do {
            // The engine downloads, merges and saves into the download folder
            let result = try await Engine.shared.call("download", [
                "url": item.sourceURL,
                "format_ids": item.choice.formatIDs,
                "ext": item.choice.ext ?? "",
                "audio": item.choice.isAudio,
                "title": item.title,
                "job_id": jobID,
            ])
            update(id) {
                $0.state = .finished
                $0.title = result["title"] as? String ?? $0.title
                $0.filePath = result["path"] as? String
            }
        } catch let error as EngineError where error.cancelled {
            update(id) { $0.state = .cancelled }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }

        poller.cancel()
        live[id] = nil
        save()
    }

    private func apply(_ progress: [String: Any], to id: UUID) {
        guard var current = live[id], let status = progress["status"] as? String else { return }
        current.downloaded = progress["downloaded"] as? Double ?? current.downloaded
        current.total = progress["total"] as? Double ?? current.total
        current.speed = progress["speed"] as? Double ?? 0
        current.part = progress["part"] as? Int ?? current.part
        current.parts = progress["parts"] as? Int ?? current.parts
        live[id] = current
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
        guard let data = try? Data(contentsOf: AppPaths.library),
              let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = decoded
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
