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
        let config = ReelsWebViewFactory.makeConfiguration()
        config.userContentController.add(context.coordinator, name: "reelsbar")
        let webView = WKWebView(frame: .zero, configuration: config)
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var appModel: AppModel?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Instagram is an SPA; enforce the audio policy after every navigation.
            appModel?.enforceDefaultAudioPolicy()
            // Dump a diagnostic snapshot once the SPA settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak webView] in
                Task { @MainActor in
                    guard let self, let webView else { return }
                    webView.evaluateJavaScript("window.__reelsbar ? window.__reelsbar.diag() : 'no-bridge'") { result, error in
                        Task { @MainActor in
                            if let error { print("[ReelsBar] diag error: \(error.localizedDescription)") }
                            else { print("[ReelsBar] diag: \(result ?? "nil")") }
                            _ = self
                        }
                    }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "reelsbar" else { return }
            let handled: (() -> Void)? = {
                if let body = message.body as? String, body == "videoEnded" {
                    return { [weak appModel] in appModel?.videoDidEnd() }
                }
                guard let dict = message.body as? [String: Any] else { return nil }
                switch dict["type"] as? String {
                case "videoEnded":
                    return { [weak appModel] in appModel?.videoDidEnd() }
                case "editing":
                    let value = dict["value"] as? Bool ?? false
                    return { [weak appModel] in appModel?.isPageEditing = value }
                case "route":
                    let value = dict["reels"] as? Bool ?? false
                    return { [weak appModel] in appModel?.setReelsTab(value) }
                case "log":
                    let value = dict["value"] as? String ?? ""
                    return { print("[ReelsBar:page] \(value)") }
                default:
                    return nil
                }
            }()
            guard let handled else { return }
            Task { @MainActor in handled() }
        }
    }
}
