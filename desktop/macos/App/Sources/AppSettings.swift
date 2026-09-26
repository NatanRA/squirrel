import Foundation
import Observation
import VideoToolbox

enum AppPaths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Squirrel", isDirectory: true)
    static let library = support.appendingPathComponent("library.json")
    /// Read by the engine too, including when the browser extension starts it.
    static let settings = support.appendingPathComponent("settings.json")
    static let defaultDownloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Squirrel", isDirectory: true)
}

/// Browsers yt-dlp can read cookies from on macOS (yt-dlp's names).
enum CookieBrowser: String, CaseIterable, Identifiable {
    case off = "", safari, chrome, firefox, edge, brave, chromium, opera, vivaldi

    var id: String { rawValue }

    var name: String {
        switch self {
        case .off: "Don't Use Cookies"
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .firefox: "Firefox"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .chromium: "Chromium"
        case .opera: "Opera"
        case .vivaldi: "Vivaldi"
        }
    }
}

/// Settings shared with the engine through settings.json (see squirrel_host.py).
@MainActor
@Observable
final class AppSettings {
    var downloadFolder: URL { didSet { save() } }
    var cookieBrowser: CookieBrowser { didSet { save() } }

    init() {
        let stored = (try? Data(contentsOf: AppPaths.settings))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        downloadFolder = (stored["download_dir"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppPaths.defaultDownloads
        cookieBrowser = CookieBrowser(rawValue: stored["cookies_from_browser"] as? String ?? "") ?? .off
        save()  // records what this Mac can play for the engine's format choices
    }

    private func save() {
        let settings: [String: Any] = [
            "download_dir": downloadFolder.path,
            "cookies_from_browser": cookieBrowser.rawValue,
            // Decides whether 1440p/4K (AV1-only on YouTube) counts as playable
            "av1_decode": VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
            "vp9_decode": false,  // QuickTime can't play VP9
        ]
        do {
            try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                .write(to: AppPaths.settings, options: .atomic)
        } catch {
            print("Failed to save settings: \(error)")
        }
    }
}
