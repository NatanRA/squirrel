import UIKit

/// Settings › Pasting › Auto-Paste Copied Links: opening the app with a newly
/// copied link pastes it and looks it up, so the format picker is one tap from a download.
@MainActor
enum AutoPaste {
    static let enabledKey = "paste.automatic"
    private static let lastChangeKey = "paste.lastChangeCount"

    /// The copied link, if the clipboard changed since the last check and holds one.
    static func newLink() async -> String? {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return nil }
        let pasteboard = UIPasteboard.general
        // changeCount goes up with every copy, so each copied link is pasted once
        let change = pasteboard.changeCount
        guard change != UserDefaults.standard.integer(forKey: lastChangeKey) else { return nil }
        UserDefaults.standard.set(change, forKey: lastChangeKey)
        // Looking for a link is silent; reading it shows iOS's paste prompt, so only read links.
        // Any result means a match: the key paths it returns don't compare equal to \.probableWebURL.
        guard let patterns = try? await pasteboard.detectedPatterns(for: [\.probableWebURL]), !patterns.isEmpty,
              let text = pasteboard.string ?? pasteboard.url?.absoluteString,
              let match = text.firstMatch(of: /https?:\/\/\S+/) else { return nil }
        return String(match.output)
    }

    /// Skips what's on the clipboard now, e.g. a link Squirrel copied itself.
    static func markSeen() {
        UserDefaults.standard.set(UIPasteboard.general.changeCount, forKey: lastChangeKey)
    }
}
