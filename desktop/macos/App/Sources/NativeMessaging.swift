import Foundation

/// Registers the engine with installed browsers so the Squirrel extension can
/// reach it (native messaging). Rewritten on every launch, so it follows the
/// app if it moves. Keep the ids in sync with extension/manifest.json.
enum NativeMessaging {
    static let hostName = "com.natan.squirrel"
    /// From the public key in extension/manifest.json
    static let chromeExtensionIDs = ["hdacmehgeiecekdneiggfemjeolmdfbc"]
    static let firefoxExtensionID = "squirrel@extension"

    /// Each browser's profile folder (in ~/Library/Application Support) and whether it's Firefox.
    private static let browsers: [(name: String, folder: String, firefox: Bool)] = [
        ("Chrome", "Google/Chrome", false),
        ("Chrome Beta", "Google/Chrome Beta", false),
        ("Chromium", "Chromium", false),
        ("Microsoft Edge", "Microsoft Edge", false),
        ("Brave", "BraveSoftware/Brave-Browser", false),
        ("Vivaldi", "Vivaldi", false),
        ("Arc", "Arc/User Data", false),
        ("Firefox", "Mozilla", true),
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
            let folder = profile.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
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
