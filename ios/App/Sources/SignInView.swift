import SwiftUI
import WebKit

struct LoginSite: Identifiable, Hashable {
    let name: String
    let url: URL
    var id: String { url.absoluteString }

    static let presets: [LoginSite] = [
        LoginSite(name: "YouTube", url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fm.youtube.com%2F")!),
        LoginSite(name: "Vimeo", url: URL(string: "https://vimeo.com/log_in")!),
        LoginSite(name: "Instagram", url: URL(string: "https://www.instagram.com/accounts/login/")!),
        LoginSite(name: "X (Twitter)", url: URL(string: "https://x.com/i/flow/login")!),
        LoginSite(name: "TikTok", url: URL(string: "https://www.tiktok.com/login")!),
        LoginSite(name: "Facebook", url: URL(string: "https://m.facebook.com/login/")!),
    ]
}

/// In-app browser for signing into a site; its cookies are exported for yt-dlp on Done.
struct SignInView: View {
    let site: LoginSite
    let onDone: () -> Void
    @State private var title = ""
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            WebView(url: site.url, title: $title, isLoading: $isLoading)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title.isEmpty ? site.name : title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        if isLoading { ProgressView() }
                    }
                }
        }
    }
}

private struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var title: String
    @Binding var isLoading: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Some providers (notably Google) refuse sign-in from embedded web views
        // that don't look like Safari.
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: WebView
        init(_ parent: WebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.title = webView.title ?? ""
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
