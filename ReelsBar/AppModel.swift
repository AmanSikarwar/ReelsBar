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

    // MARK: - Lifecycle

    private var lifecycleObservers: [NSObjectProtocol] = []

    func startLifecycleObservation() {
        let center = NotificationCenter.default

        lifecycleObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePanelDeactivated() }
        })

        lifecycleObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePanelActivated() }
        })

        lifecycleObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, let keyWindow = note.object as? NSWindow,
                      keyWindow === self.webView?.window else { return }
                self.handlePanelActivated()
            }
        })

        lifecycleObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, let keyWindow = note.object as? NSWindow,
                      keyWindow === self.webView?.window else { return }
                self.handlePanelDeactivated()
            }
        })
    }

    /// Pause playback, silence audio, and suspend background work while hidden.
    func handlePanelDeactivated() {
        guard isPanelActive else { return }
        isPanelActive = false
        runJS("window.__reelsbar && (window.__reelsbar.pauseAll(), window.__reelsbar.setMuted(true))")
        suspendAutoScrollTimer()
    }

    /// Restore readiness and the user's prior mute choice when visible again.
    func handlePanelActivated() {
        guard !isPanelActive, webView != nil, NSApp.isActive else { return }
        isPanelActive = true
        runJS("window.__reelsbar && (window.__reelsbar.setMuted(\(isMuted)), window.__reelsbar.resumeActive())")
        resumeAutoScrollTimer()
    }

    // MARK: - Auto-scroll timer suspension hook (engine wired in Phase 8)

    var autoScrollTimer: Timer?

    func suspendAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    func resumeAutoScrollTimer() {
        // The `ended`-event engine handles advancement; the fallback timer
        // is only armed by the auto-scroll toggle while the panel is active.
    }
}
