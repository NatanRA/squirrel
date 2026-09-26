import Foundation

/// Registers the engine with installed browsers so the Squirrel extension can
/// reach it (native messaging). Rewritten on every launch, so it follows the
/// app if it moves. Keep the ids in sync with extension/manifest.json.
enum NativeMessaging {
    static let hostName = "app.squirrel"
    /// From the public key in extension/manifest.json
    static let chromeExtensionIDs = ["hdacmehgeiecekdneiggfemjeolmdfbc"]
    static let firefoxExtensionID = "squirrel@extension"

    /// Installs the host manifest for every browser on this Mac (see Browsers.onThisMac); returns their names.
    @discardableResult
    static func register() -> [String] {
        var registered: [String] = []
        for browser in Browsers.onThisMac() {
            let folders = hostFolders(for: browser)
            guard !folders.isEmpty else { continue }
            var manifest: [String: Any] = [
                "name": hostName,
                "description": "Squirrel downloads",
                "path": Engine.executable.path,
                "type": "stdio",
            ]
            if browser.kind == .firefox {
                manifest["allowed_extensions"] = [firefoxExtensionID]
            } else {
                manifest["allowed_origins"] = chromeExtensionIDs.map { "chrome-extension://\($0)/" }
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                for folder in folders {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: folder.appendingPathComponent("\(hostName).json"), options: .atomic)
                }
                registered.append(browser.name)
            } catch {
                print("Couldn't register with \(browser.name): \(error)")
            }
        }
        return registered
    }

    /// Where a browser looks for native messaging hosts. Chromium browsers may read Chrome's folder
    /// rather than their own (Brave does, even without Chrome installed), so they get both. Firefox
    /// reads Mozilla's, and browsers built on it their own folder or Mozilla's.
    static func hostFolders(for browser: BrowserStatus) -> [URL] {
        let hosts = "NativeMessagingHosts"
        switch browser.kind {
        case .chromium:
            let chrome = Browsers.support.appendingPathComponent("Google/Chrome/\(hosts)", isDirectory: true)
            let own = browser.dataFolder.map { $0.appendingPathComponent(hosts, isDirectory: true) }
            return own == nil || own == chrome ? [chrome] : [own!, chrome]
        case .firefox:
            var folders = [Browsers.support.appendingPathComponent("Mozilla/\(hosts)", isDirectory: true)]
            if let data = browser.dataFolder, data.lastPathComponent != "Firefox" {
                folders.append(data.appendingPathComponent(hosts, isDirectory: true))
            }
            return folders
        case .safari:
            return []
        }
    }
}
