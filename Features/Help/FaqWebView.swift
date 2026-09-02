import SwiftUI
import WebKit
import Combine

/// Web tabanlı SSS — Android `FaqWebFragment` + `fragment_faq_web.xml` portu.
///
/// `verifyblind.com/{locale}/sss?onlycontent` sayfasını gömülü WKWebView'de açar (yalnız içerik,
/// site chrome'u olmadan). Custom User-Agent son eki backend'in in-app WebView isteğini tanıyıp
/// Turnstile'ı atlamasını sağlar (Android `VerifyBlind-Android-WebView` paritesi).
struct FaqWebView: View {
    let onBack: () -> Void
    @State private var progress: Double = 0
    @State private var isLoading = true

    private var url: URL {
        let lang = (Locale.current.language.languageCode?.identifier == "tr") ? "tr" : "en"
        return URL(string: "https://verifyblind.com/\(lang)/sss?onlycontent")!
    }

    var body: some View {
        VStack(spacing: 0) {
            NavTopBar(title: L.t("settings_faq_title"), titleColor: Theme.onSurface, titleSize: 18, onBack: onBack)
            ZStack(alignment: .top) {
                WebPage(url: url, progress: $progress, isLoading: $isLoading)
                if isLoading {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.themePrimary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}

/// WKWebView SwiftUI sarmalı. İlerleme KVO yerine Combine `publisher(for:)` ile izlenir
/// (observer manuel kaldırma / çift-kayıt crash riski yok).
private struct WebPage: UIViewRepresentable {
    let url: URL
    @Binding var progress: Double
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Default UA'ya " VerifyBlind-iOS-WebView" eklenir → backend in-app WebView'i tanır.
        config.applicationNameForUserAgent = "VerifyBlind-iOS-WebView"
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        context.coordinator.observe(webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebPage
        private var cancellable: AnyCancellable?

        init(_ parent: WebPage) { self.parent = parent }

        func observe(_ webView: WKWebView) {
            cancellable = webView.publisher(for: \.estimatedProgress).sink { [parent] p in
                parent.progress = p
                parent.isLoading = p < 1.0
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
