import SwiftUI
import WebKit

@Observable
@MainActor
final class AppModel {
    var isMuted = true
    var isAutoScrollActive = false
    var isPanelActive = false

    weak var webView: WKWebView?

    func runJS(_ js: String) {
        webView?.evaluateJavaScript(js)
    }

    // MARK: - Audio

    func setMuted(_ muted: Bool) {
        isMuted = muted
        runJS("window.__reelsbar && window.__reelsbar.setMuted(\(muted))")
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    /// Re-assert mute-by-default on every page load or reload.
    func enforceDefaultAudioPolicy() {
        isMuted = true
        runJS("window.__reelsbar && window.__reelsbar.setMuted(true)")
    }
}
