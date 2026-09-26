import Foundation
import Observation

/// Checks GitHub for a newer release of Squirrel itself when the app opens, so it can offer it.
/// (UpdateManager is separate: it keeps yt-dlp up to date inside the app.)
@MainActor
@Observable
final class AppUpdateChecker {
    struct Release: Equatable {
        let version: String
        /// The release page, with its notes and every download
        let page: URL
        /// This platform's download, when the release has one
        let download: URL?
    }

    enum Status: Equatable {
        case idle, checking, upToDate, failed
    }

    /// A newer release the user hasn't dismissed
    private(set) var available: Release?
    /// A newer release, including one the user put off
    private(set) var newer: Release?
    private(set) var status = Status.idle
    private(set) var lastCheck: Date?

    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private static let latestRelease = URL(string: "https://api.github.com/repos/NatanRA/squirrel/releases/latest")!
    private static let dismissedKey = "appUpdate.dismissedVersion"
    #if os(macOS) && arch(arm64)
    private static let assetName = "Squirrel-macos-arm64.dmg"
    #elseif os(macOS)
    private static let assetName = "Squirrel-macos-x86_64.dmg"
    #else
    private static let assetName = "Squirrel.ipa"
    #endif

    /// When the app opens: offers a newer version unless the user chose Not Now for it.
    func check() async {
        await check(offeringDismissed: false)
    }

    /// Check for Updates: offers any newer version, including one put off with Not Now.
    func checkNow() async {
        await check(offeringDismissed: true)
    }

    private func check(offeringDismissed: Bool) async {
        guard status != .checking else { return }
        status = .checking
        guard let release = await Self.latest() else {
            status = .failed
            return
        }
        lastCheck = .now
        guard Self.isNewer(release.version, than: Self.currentVersion) else {
            available = nil
            newer = nil
            status = .upToDate
            return
        }
        newer = release
        status = .idle
        if offeringDismissed {
            UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
        } else if release.version == UserDefaults.standard.string(forKey: Self.dismissedKey) {
            return
        }
        available = release
    }

    /// The newest release on GitHub, or nil when it can't be reached.
    private static func latest() async -> Release? {
        var request = URLRequest(url: latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = release["tag_name"] as? String,
              let page = (release["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = release["assets"] as? [[String: Any]] ?? []
        let download = assets.first { $0["name"] as? String == assetName }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
        return Release(version: version, page: page, download: download)
    }

    /// Hides this version; the next one is offered again.
    func dismiss() {
        if let version = available?.version {
            UserDefaults.standard.set(version, forKey: Self.dismissedKey)
        }
        available = nil
    }

    /// "1.10.0" is newer than "1.9.2"
    static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = other.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
