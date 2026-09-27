import AppKit
import UserNotifications

/// A notification when a download finishes or fails (Settings › General); clicking it shows the
/// file in Finder.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let enabledKey = "notifications.enabled"

    private var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
    private var center: UNUserNotificationCenter { .current() }

    func start() {
        center.delegate = self
    }

    /// Asked on the first download rather than at launch, when it's clear what it's for.
    func requestPermission() {
        guard enabled else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func finished(_ item: DownloadItem) {
        post(item, title: "Downloaded", body: item.title)
    }

    func failed(_ item: DownloadItem, _ message: String) {
        post(item, title: "Download Failed", body: "\(item.title): \(message)")
    }

    /// One notification for a playlist rather than one per video; clicking it shows one of the files.
    func playlistFinished(title: String, done: Int, failed: Int, file: String?) {
        guard done + failed > 0 else { return }  // all cancelled
        var body = done == 1 ? "1 download" : "\(done) downloads"
        if failed > 0 { body += ", \(failed) failed" }
        post(id: UUID().uuidString, title: title, body: body, path: file)
    }

    private func post(_ item: DownloadItem, title: String, body: String) {
        post(id: item.id.uuidString, title: title, body: body, path: item.filePath)
    }

    private func post(id: String, title: String, body: String, path: String?) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let path { content.userInfo = ["path": path] }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                if allowed {
                    self.center.add(request)
                } else if !NSApp.isActive {
                    // No notifications (turned off, or macOS doesn't allow them for this copy): bounce the Dock icon
                    NSApp.requestUserAttention(.informationalRequest)
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        completionHandler()
    }

    /// Shown even while Squirrel is in front, since the window may be behind the browser.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

/// Progress on the Dock icon while downloads run: a bar across the icon and a count badge.
@MainActor
final class DockProgress {
    static let shared = DockProgress()

    private let bar = DockProgressBar()

    func update(active: Int, fraction: Double?) {
        let tile = NSApp.dockTile
        tile.badgeLabel = active > 0 ? "\(active)" : nil
        if active > 0 {
            if tile.contentView == nil { tile.contentView = makeView(size: tile.size) }
            bar.fraction = fraction ?? 0
        } else {
            tile.contentView = nil
        }
        tile.display()
    }

    private func makeView(size: NSSize) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        let icon = NSImageView(frame: view.bounds)
        icon.image = NSApp.applicationIconImage
        view.addSubview(icon)
        bar.frame = NSRect(x: size.width * 0.12, y: size.height * 0.12, width: size.width * 0.76, height: size.height * 0.13)
        view.addSubview(bar)
        return view
    }
}

/// A dark track with a white fill: the system progress bar is too pale to see on the cream icon.
private final class DockProgressBar: NSView {
    var fraction = 0.0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let filled = NSRect(x: inset.minX, y: inset.minY, width: max(inset.height, inset.width * min(max(fraction, 0), 1)), height: inset.height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: filled, xRadius: inset.height / 2, yRadius: inset.height / 2).fill()
    }
}
