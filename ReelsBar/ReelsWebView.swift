import SwiftUI
import WebKit

enum ReelsWebViewFactory {
    static let reelsURL = URL(string: "https://www.instagram.com/reels/")!

    static let iPhoneUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = iPhoneUserAgent
        ReelsUserScript.inject(into: config.userContentController)
        return config
    }
}

struct ReelsWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: ReelsWebViewFactory.makeConfiguration())
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.customUserAgent = ReelsWebViewFactory.iPhoneUserAgent
        webView.allowsBackForwardNavigationGestures = false
        webView.load(URLRequest(url: ReelsWebViewFactory.reelsURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.setAttribute('data-reelsbar', 'loaded')")
        }
    }
}
