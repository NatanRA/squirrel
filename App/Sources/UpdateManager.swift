import Foundation
import Observation

/// Keeps the embedded yt-dlp current by installing newer releases from PyPI
/// (see ytdl_updater.py). Updates apply on the next launch.
@MainActor
@Observable
final class UpdateManager {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case installing(String)
        /// Installed; takes effect after the app restarts.
        case restartRequired(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var runningVersion: String?
    private(set) var bundledVersion: String?
    private(set) var isUsingUpdate = false
    /// Set when an installed update failed to import and was disabled.
    private(set) var loadError: String?

    var nightly: Bool {
        didSet {
            UserDefaults.standard.set(nightly, forKey: Keys.nightly)
            phase = .idle
        }
    }

    private enum Keys {
        static let nightly = "updates.nightly"
        static let lastCheck = "updates.lastCheck"
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
            phase = .restartRequired(pending)
        }
    }

    /// Checks at most once a day; call on launch.
    func checkIfDue() async {
        let last = UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > 24 * 3600, phase == .idle else { return }
        await check(quietly: true)
    }

    func check(quietly: Bool = false) async {
        if case .restartRequired = phase { return }
        phase = .checking
        do {
            let result = try await PythonRuntime.shared.call("check_update", ["nightly": nightly])
            UserDefaults.standard.set(Date.now, forKey: Keys.lastCheck)
            if result["available"] as? Bool == true, let latest = result["latest"] as? String {
                phase = .available(latest)
            } else {
                phase = quietly ? .idle : .upToDate
            }
        } catch {
            phase = quietly ? .idle : .failed(error.localizedDescription)
        }
    }

    func install(_ version: String) async {
        phase = .installing(version)
        do {
            _ = try await PythonRuntime.shared.call("install_update", ["version": version])
            phase = .restartRequired(version)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Removes any downloaded update; the built-in version loads next launch.
    func revertToBundled() async {
        _ = try? await PythonRuntime.shared.call("remove_update", [:])
        loadError = nil
        phase = isUsingUpdate ? .restartRequired(bundledVersion ?? "built-in") : .idle
    }

    var availableVersion: String? {
        if case .available(let version) = phase { return version }
        return nil
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
