import BackgroundTasks
import OSLog
import UIKit

private let log = Logger(subsystem: "app.squirrel", category: "background")

/// Keeps the download queue running after the user leaves the app.
///
/// On iOS 26+ this submits a `BGContinuedProcessingTask`, which lets the work
/// continue in the background while the system shows its progress. Earlier
/// versions only get the ~30 s grace period of a UIKit background task.
/// iOS only accepts either while the app is open, so one is started from the
/// user's own actions and covers every download until the queue runs out.
@MainActor
final class BackgroundContinuation {
    private let onExpire: @MainActor () -> Void
    private var systemTask: BGTask?
    private var legacyTask: UIBackgroundTaskIdentifier = .invalid
    private var isFinished = false
    private var title: String
    private var subtitle: String
    private var fraction: Double

    init(title: String, subtitle: String, fraction: Double, onExpire: @escaping @MainActor () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.fraction = fraction
        self.onExpire = onExpire
        beginLegacyTask()
        if #available(iOS 26, *) {
            submitContinuedProcessingTask()
        }
    }

    func update(title: String, subtitle: String, fraction: Double) {
        self.title = title
        self.subtitle = subtitle
        self.fraction = fraction
        guard #available(iOS 26, *), let task = systemTask as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = Int64(fraction * 1000)
        task.updateTitle(title, subtitle: subtitle)
    }

    /// More downloads were started in the app: a new grace period if the last one ran out.
    func renew() {
        guard !isFinished, legacyTask == .invalid else { return }
        beginLegacyTask()
    }

    func finish(success: Bool) {
        isFinished = true
        systemTask?.setTaskCompleted(success: success)
        systemTask = nil
        endLegacyTask()
    }

    private func beginLegacyTask() {
        legacyTask = UIApplication.shared.beginBackgroundTask(withName: "download") { [weak self] in
            MainActor.assumeIsolated { self?.endLegacyTask() }
        }
    }

    private func endLegacyTask() {
        guard legacyTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(legacyTask)
        legacyTask = .invalid
    }

    // MARK: - iOS 26 continued processing

    /// The permitted wildcard (e.g. "app.squirrel.download.*") from Info.plist.
    private static let identifierPrefix: String? = {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        return permitted?.first { $0.hasSuffix(".*") }.map { String($0.dropLast()) }
    }()

    @available(iOS 26, *)
    private func submitContinuedProcessingTask() {
        guard let prefix = Self.identifierPrefix else { return }
        // Handlers can't be re-registered, so every attempt gets a fresh identifier.
        let identifier = prefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self else { return task.setTaskCompleted(success: false) }
                self.attach(task)
            }
        }
        // Fails if a sideloading tool rewrote the bundle ID; the legacy task still applies.
        guard registered else {
            log.notice("Continued processing not permitted for \(identifier, privacy: .public)")
            return
        }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.notice("Continued processing unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    @available(iOS 26, *)
    private func attach(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask, !isFinished else {
            task.setTaskCompleted(success: true)
            return
        }
        log.info("Continued processing task started")
        systemTask = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(fraction * 1000)
        task.updateTitle(title, subtitle: subtitle)
        // Fired when the system reclaims resources or the user stops it from the progress UI.
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isFinished else { return }
                self.onExpire()
                self.finish(success: false)
            }
        }
    }
}
