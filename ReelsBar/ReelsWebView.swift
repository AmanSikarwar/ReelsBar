import SwiftUI
import WebKit
import CoreGraphics

enum ReelsWebViewFactory {
    static let reelsURL = URL(string: "https://www.instagram.com/reels/")!

    static let iPhoneUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        // NOTE: customUserAgent on the WKWebView itself is the single source
        // of truth (applicationNameForUserAgent only appends to the default
        // macOS UA, so setting a full iPhone string there would corrupt it).
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
                case "needMore":
                    guard let webView = message.webView else { return nil }
                    let gentle = dict["gentle"] as? Bool ?? false
                    return { [weak self] in self?.nudgeForMore(webView, gentle: gentle) }
                default:
                    return nil
                }
            }()
            guard let handled else { return }
            Task { @MainActor in handled() }
        }

        /// Emulates a short trackpad flick so Instagram's feed loader sees
        /// genuine scroll input (with real momentum/rubber-band behavior)
        /// and fetches the next batch of reels. `gentle` keeps the gesture
        /// small while the user is still watching the penultimate reel.
        private var lastNudgeAt = Date.distantPast
        private func nudgeForMore(_ webView: WKWebView, gentle: Bool) {
            guard let window = webView.window, window.isVisible else { return }
            guard Date().timeIntervalSince(lastNudgeAt) > 0.6 else { return }
            lastNudgeAt = Date()

            // Aim the events at the centre of the panel window. NSWindow
            // frames use bottom-left screen coordinates; CGEvent locations
            // are measured from the top of the primary display.
            let frame = window.frame
            guard let primaryScreen = NSScreen.screens.first else { return }
            var location = CGPoint()
            location.x = frame.midX
            location.y = primaryScreen.frame.maxY - frame.midY

            let steps: Int = gentle ? 4 : 12
            let pixelsPerStep: Int32 = gentle ? 20 : 30
            let pid = ProcessInfo.processInfo.processIdentifier

            print("[ReelsBar] nudge gentle=\(gentle) at \(location)")
            for step in 0..<steps {
                let delay = Double(step) * 0.03
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard window.isVisible else { return }
                    self?.postScrollStep(pid: pid, location: location,
                                         pixels: -pixelsPerStep)
                }
            }
        }

        /// Posts one synthetic pixel-precision scroll-wheel tick to this
        /// app's own process, routed through the normal input pipeline.
        private func postScrollStep(pid: pid_t, location: CGPoint, pixels: Int32) {
            let stateID = CGEventSourceStateID.hidSystemState
            guard let source = CGEventSource(stateID: stateID) else { return }
            let wheelCount = UInt32(1)
            let unit = CGScrollEventUnit.pixel
            let deltaX = Int32(0)
            let deltaZ = Int32(0)
            guard let event = CGEvent(scrollWheelEvent2Source: source,
                                      units: unit,
                                      wheelCount: wheelCount,
                                      wheel1: pixels,
                                      wheel2: deltaX,
                                      wheel3: deltaZ) else { return }
            event.location = location
            event.postToPid(pid)
        }
    }
}
