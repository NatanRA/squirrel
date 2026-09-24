import Foundation

enum AppPaths {
    /// User-visible downloads (exposed in the Files app).
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]

    static let library = applicationSupport.appendingPathComponent("library.json")
    /// Over-the-air yt-dlp updates (see ytdl_updater.py).
    static let pythonUpdates = applicationSupport.appendingPathComponent("python-updates", isDirectory: true)
    static let cookies = applicationSupport.appendingPathComponent("cookies", isDirectory: true)
    static let downloadWork = caches.appendingPathComponent("work", isDirectory: true)
    static let ytdlpCache = caches.appendingPathComponent("yt-dlp", isDirectory: true)
}
