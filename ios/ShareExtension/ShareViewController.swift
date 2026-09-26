import UIKit
import UniformTypeIdentifiers

/// Squirrel in the share sheet. yt-dlp can't run inside an extension, so this hands the
/// shared link to the app as squirrel://download?url=…, which looks it up straight away.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await handOff() }
    }

    private func handOff() async {
        guard let link = await sharedLink() else { return finish() }
        var components = URLComponents(string: "squirrel://download")!
        components.queryItems = [URLQueryItem(name: "url", value: link)]
        if let url = components.url, openInApp(url) { return finish() }
        // iOS didn't let the extension open the app: leave the link ready to paste instead
        UIPasteboard.general.string = link
        showCopiedMessage()
    }

    /// The first web link shared: a URL item, or one inside shared text ("Check this out https://…").
    private func sharedLink() async -> String? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            if let url = await load(URL.self, from: provider), ["http", "https"].contains(url.scheme?.lowercased()) {
                return url.absoluteString
            }
        }
        for provider in providers where provider.canLoadObject(ofClass: String.self) {
            if let text = await load(String.self, from: provider), let match = text.firstMatch(of: /https?:\/\/\S+/) {
                return String(match.output)
            }
        }
        return nil
    }

    private func load<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
    where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { object, _ in continuation.resume(returning: object) }
        }
    }

    /// Share extensions have no public way to open their app, so this finds the application
    /// object in the responder chain and calls open(_:options:completionHandler:) through the
    /// Objective-C runtime (the method is off limits to extensions at compile time).
    private func openInApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func showCopiedMessage() {
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Link Copied"
        title.font = .preferredFont(forTextStyle: .headline)
        let message = UILabel()
        message.text = "Open Squirrel and it's ready to paste."
        message.textColor = .secondaryLabel
        message.numberOfLines = 0
        message.textAlignment = .center
        let done = UIButton(configuration: .borderedProminent(), primaryAction: UIAction(title: "Done") { [weak self] _ in
            self?.finish()
        })
        let stack = UIStackView(arrangedSubviews: [title, message, done])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
        ])
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
