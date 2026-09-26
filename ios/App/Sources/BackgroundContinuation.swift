import BackgroundTasks
import OSLog
import UIKit

private let log = Logger(subsystem: "app.squirrel", category: "background")

/// Keeps one download running after the user leaves the app.
///
/// On iOS 26+ this submits a `BGContinuedProcessingTask`, which lets the work
/// continue in the background while the system shows its progress. Earlier
/// versions only get the ~30 s grace period of a UIKit background task.
@MainActor
final class BackgroundContinuation {
    private let title: String
    private let onExpire: @MainActor () -> Void
    private var systemTask: BGTask?
    private var legacyTask: UIBackgroundTaskIdentifier = .invalid
    private var isFinished = false
    private var fraction: Double = 0
    private var subtitle = "Starting…"

    init(title: String, onExpire: @escaping @MainActor () -> Void) {
        self.title = title
        self.onExpire = onExpire
        legacyTask = UIApplication.shared.beginBackgroundTask(withName: "download") { [weak self] in
            MainActor.assumeIsolated { self?.endLegacyTask() }
        }
        if #available(iOS 26, *) {
            submitContinuedProcessingTask()
        }
    }

    func update(fraction: Double?, subtitle: String) {
        if let fraction { self.fraction = fraction }
        self.subtitle = subtitle
        guard #available(iOS 26, *), let task = systemTask as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = Int64(self.fraction * 1000)
        task.updateTitle(title, subtitle: subtitle)
    }

    func finish(success: Bool) {
        isFinished = true
        systemTask?.setTaskCompleted(success: success)
        systemTask = nil
        endLegacyTask()
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
