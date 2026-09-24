import Foundation
import Observation

/// Keeps the embedded yt-dlp current by installing newer releases from PyPI
/// (see ytdl_updater.py). Runs silently: at most once a day it checks, downloads
/// and stages an update, which takes effect the next time the app starts. The
/// built-in copy remains as the fallback if an update fails to load.
@MainActor
@Observable
final class UpdateManager {
    enum Phase: Equatable {
        case idle
        case checking
        case installing(String)
        /// Installed on disk; used from the next launch.
        case ready(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var runningVersion: String?
    private(set) var bundledVersion: String?
    private(set) var isUsingUpdate = false
    /// Set when an installed update failed to import and was disabled.
    private(set) var loadError: String?
    /// Whether the last manual check found nothing newer.
    private(set) var isUpToDate = false

    var lastCheck: Date? { UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date }

    var nightly: Bool {
        didSet {
            UserDefaults.standard.set(nightly, forKey: Keys.nightly)
            // Switching channel should take effect without waiting a day.
            UserDefaults.standard.removeObject(forKey: Keys.lastCheck)
            Task { await autoUpdateIfDue() }
        }
    }

    private enum Keys {
        static let nightly = "updates.nightly"
        static let lastCheck = "updates.lastCheck"
        /// A version the user reverted; not reinstalled automatically.
        static let skipped = "updates.skippedVersion"
    }

    init() {
        nightly = UserDefaults.standard.bool(forKey: Keys.nightly)
    }

    func refreshStatus() async {
        guard let status = try? await PythonRuntime.shared.call("update_status", [:]) else { return }
        runningVersion = status["version"] as? String
        bundledVersion = status["bundled_version"] as? String
        isUsingUpdate = status["source"] as? String == "update"
        loadError = status["load_error"] as? String
        // An update installed on disk that isn't the one running yet.
        if let pending = status["pending_version"] as? String,
           Self.normalized(pending) != Self.normalized(runningVersion) {
            phase = .ready(pending)
        }
    }

    /// Checks at most once a day; safe to call on every launch and foreground.
    func autoUpdateIfDue() async {
        guard !isBusy, Date.now.timeIntervalSince(lastCheck ?? .distantPast) > 24 * 3600 else { return }
        await update(manual: false)
    }

    /// Checks right away from Settings, including versions previously reverted.
    func checkNow() async {
        guard !isBusy else { return }
        UserDefaults.standard.removeObject(forKey: Keys.skipped)
        await update(manual: true)
    }

    /// Removes any downloaded update; the built-in version is used from the next launch.
    func revertToBundled() async {
        let reverted: String?
        if case .ready(let pending) = phase { reverted = pending } else { reverted = isUsingUpdate ? runningVersion : nil }
        _ = try? await PythonRuntime.shared.call("remove_update", [:])
        // Otherwise the next automatic check would reinstall the same version.
        if let reverted { UserDefaults.standard.set(Self.normalized(reverted), forKey: Keys.skipped) }
        loadError = nil
        isUpToDate = false
        phase = isUsingUpdate ? .ready(bundledVersion ?? "built-in") : .idle
    }

    private var isBusy: Bool {
        switch phase {
        case .checking, .installing: true
        default: false
        }
    }

    private func update(manual: Bool) async {
        let previous = phase
        phase = .checking
        isUpToDate = false
        do {
            let result = try await PythonRuntime.shared.call("check_update", ["nightly": nightly])
            let skipped = UserDefaults.standard.string(forKey: Keys.skipped)
            guard result["available"] as? Bool == true,
                  let latest = result["latest"] as? String,
                  manual || Self.normalized(latest) != skipped else {
                UserDefaults.standard.set(Date.now, forKey: Keys.lastCheck)
                isUpToDate = manual
                phase = previous == .checking ? .idle : previous
                return
            }
            phase = .installing(latest)
            _ = try await PythonRuntime.shared.call("install_update", ["version": latest])
            // Only record the check once the update is safely installed, so a
            // failed download is retried on the next launch.
            UserDefaults.standard.set(Date.now, forKey: Keys.lastCheck)
            phase = .ready(latest)
        } catch {
            phase = manual ? .failed(error.localizedDescription) : previous
        }
    }

    /// "2026.9.16.232951.dev0" -> "2026.9.16 (nightly)"
    static func display(_ version: String) -> String {
        let parts = version.split(separator: ".")
        guard parts.count > 3 else { return version }
        return parts.prefix(3).joined(separator: ".") + " (nightly)"
    }

    /// yt-dlp's own version strings zero-pad ("2026.08.19"), PyPI's don't.
    static func normalized(_ version: String?) -> String {
        (version ?? "").split(separator: ".").compactMap { Int($0) }.map(String.init).joined(separator: ".")
    }
}
