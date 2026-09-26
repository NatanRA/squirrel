import AppKit
import SafariServices

/// Receives links from the Safari extension (extension/safari/background.js) and hands them to
/// the Squirrel app as squirrel://download?url=…, the same way the Share menu does.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var opened = false
        if let link = message?["url"] as? String, var components = URLComponents(string: "squirrel://download") {
            components.queryItems = [URLQueryItem(name: "url", value: link)]
            if let url = components.url { opened = NSWorkspace.shared.open(url) }
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": opened]]
        context.completeRequest(returningItems: [response])
    }
}
