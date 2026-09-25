import AppKit

/// Squirrel in the Share menu. The download engine runs in the app, so this hands the shared
/// link over as squirrel://download?url=…, which opens Squirrel and looks the link up.
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await handOff() }
    }

    private func handOff() async {
        guard let link = await sharedLink() else {
            return extensionContext!.cancelRequest(withError: CocoaError(.featureUnsupported))
        }
        var components = URLComponents(string: "squirrel://download")!
        components.queryItems = [URLQueryItem(name: "url", value: link)]
        NSWorkspace.shared.open(components.url!)
        extensionContext!.completeRequest(returningItems: nil)
    }

    /// The first web link shared: a URL item, or one inside shared text.
    private func sharedLink() async -> String? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers where provider.canLoadObject(ofClass: NSURL.self) {
            if let url = await load(NSURL.self, from: provider) as URL?, ["http", "https"].contains(url.scheme?.lowercased()) {
                return url.absoluteString
            }
        }
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            if let text = await load(NSString.self, from: provider) as String?,
               let match = text.range(of: #"https?://\S+"#, options: .regularExpression) {
                return String(text[match])
            }
        }
        return nil
    }

    private func load<T: NSItemProviderReading>(_ type: T.Type, from provider: NSItemProvider) async -> T? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { object, _ in continuation.resume(returning: object as? T) }
        }
    }
}
