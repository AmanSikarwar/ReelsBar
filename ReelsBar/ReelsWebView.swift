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
    @Environment(AppModel.self) private var appModel

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: ReelsWebViewFactory.makeConfiguration())
        webView.customUserAgent = ReelsWebViewFactory.iPhoneUserAgent
        webView.navigationDelegate = context.coordinator
        context.coordinator.appModel = appModel
        appModel.webView = webView
        webView.load(URLRequest(url: ReelsWebViewFactory.reelsURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.appModel = appModel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var appModel: AppModel?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Instagram is an SPA; enforce the audio policy after every navigation.
            appModel?.enforceDefaultAudioPolicy()
        }
    }
}
