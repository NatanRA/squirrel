import Foundation

/// Registers the engine with installed browsers so the Squirrel extension can
/// reach it (native messaging). Rewritten on every launch, so it follows the
/// app if it moves. Keep the ids in sync with extension/manifest.json.
enum NativeMessaging {
    static let hostName = "app.squirrel"
    /// From the public key in extension/manifest.json
    static let chromeExtensionIDs = ["hdacmehgeiecekdneiggfemjeolmdfbc"]
    static let firefoxExtensionID = "squirrel@extension"

    /// Each browser's data folder (in ~/Library/Application Support), which shows it's installed,
    /// and where it looks for native messaging hosts. Firefox keeps its data in "Firefox" but
    /// reads hosts from "Mozilla".
    private static let browsers: [(name: String, folder: String, hosts: String, firefox: Bool)] = [
        ("Chrome", "Google/Chrome", "Google/Chrome/NativeMessagingHosts", false),
        ("Chrome Beta", "Google/Chrome Beta", "Google/Chrome Beta/NativeMessagingHosts", false),
        ("Chromium", "Chromium", "Chromium/NativeMessagingHosts", false),
        ("Microsoft Edge", "Microsoft Edge", "Microsoft Edge/NativeMessagingHosts", false),
        ("Brave", "BraveSoftware/Brave-Browser", "BraveSoftware/Brave-Browser/NativeMessagingHosts", false),
        ("Vivaldi", "Vivaldi", "Vivaldi/NativeMessagingHosts", false),
        ("Arc", "Arc/User Data", "Arc/User Data/NativeMessagingHosts", false),
        ("Firefox", "Firefox", "Mozilla/NativeMessagingHosts", true),
    ]

    /// Installs the host manifest for every installed browser; returns their names.
    @discardableResult
    static func register() -> [String] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var registered: [String] = []
        for browser in browsers {
            let profile = support.appendingPathComponent(browser.folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: profile.path) else { continue }
            var manifest: [String: Any] = [
                "name": hostName,
                "description": "Squirrel downloads",
                "path": Engine.executable.path,
                "type": "stdio",
            ]
            if browser.firefox {
                manifest["allowed_extensions"] = [firefoxExtensionID]
            } else {
                manifest["allowed_origins"] = chromeExtensionIDs.map { "chrome-extension://\($0)/" }
            }
            let folder = support.appendingPathComponent(browser.hosts, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.appendingPathComponent("\(hostName).json"), options: .atomic)
                registered.append(browser.name)
            } catch {
                print("Couldn't register with \(browser.name): \(error)")
            }
        }
        return registered
    }
}
