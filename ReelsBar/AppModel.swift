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

    // MARK: - Keyboard actions (guarded against text-field typing)

    private func runIfNotEditing(_ js: @autoclosure @escaping () -> String, native: (() -> Void)? = nil) {
        guard let webView else { return }
        webView.evaluateJavaScript("window.__reelsbar ? !window.__reelsbar.isEditing() : false") { result, _ in
            Task { @MainActor in
                guard result as? Bool == true else { return }
                webView.evaluateJavaScript(js())
                native?()
            }
        }
    }

    func scrollNext() {
        runIfNotEditing("window.__reelsbar && window.__reelsbar.scrollNext()")
    }

    func scrollPrev() {
        runIfNotEditing("window.__reelsbar && window.__reelsbar.scrollPrev()")
    }

    func togglePlay() {
        runIfNotEditing("window.__reelsbar && window.__reelsbar.togglePlay()")
    }

    func like() {
        runIfNotEditing("window.__reelsbar && window.__reelsbar.like()")
    }

    func toggleAutoScroll() {
        isAutoScrollActive.toggle()
        runJS("window.__reelsbar && window.__reelsbar.setAutoScroll(\(isAutoScrollActive))")
        if isAutoScrollActive {
            armAutoScrollFallbackTimer()
        } else {
            suspendAutoScrollTimer()
        }
    }

    // MARK: - Auto-scroll engine

    /// How long without a native `ended` event before the fallback timer advances.
    static let autoScrollFallbackInterval: TimeInterval = 120

    private(set) var lastVideoEndedAt: Date?

    func videoDidEnd() {
        lastVideoEndedAt = Date()
    }

    private func armAutoScrollFallbackTimer() {
        suspendAutoScrollTimer()
        guard isPanelActive else { return }
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: Self.autoScrollFallbackInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isAutoScrollActive, self.isPanelActive else { return }
                let stalled = self.lastVideoEndedAt.map { Date().timeIntervalSince($0) > Self.autoScrollFallbackInterval } ?? true
                if stalled { self.scrollNext() }
            }
        }
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

    // MARK: - Local keyboard monitoring (active window only)

    private var localKeyMonitor: Any?

    func startKeyboardMonitoring() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isPanelActive,
                      !event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                          .contains(.command) else { return event }
                switch event.keyCode {
                case 49: self.togglePlay()            // Space
                case 126: self.scrollPrev()           // Up
                case 125: self.scrollNext()           // Down
                case 46: self.runIfNotEditing(
                    "window.__reelsbar && window.__reelsbar.setMuted(\(self.isMuted ? "false" : "true"))",
                    native: { self.isMuted.toggle() })  // M
                case 0: self.toggleAutoScroll()       // A
                case 37: self.like()                  // L
                default: break
                }
                return event
            }
        }
    }

    // MARK: - Global hotkey (⌘⇧R) panel toggle

    private var hotkeyManager: HotkeyManager?

    func startGlobalHotkey() {
        guard hotkeyManager == nil else { return }
        hotkeyManager = HotkeyManager { [weak self] in
            Task { @MainActor in self?.togglePanelFromHotkey() }
        }
        hotkeyManager?.register()
    }

    func togglePanelFromHotkey() {
        if let window = webView?.window, window.isVisible {
            window.orderOut(nil)
            handlePanelDeactivated()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            // MenuBarExtra's status item window hosts the toggle button.
            let statusButton = NSApp.windows
                .first { String(describing: type(of: $0)).contains("NSStatusBarWindow") }?
                .contentView?.subviews.compactMap { $0 as? NSStatusBarButton }.first
            statusButton?.performClick(nil)
        }
    }

    // MARK: - Auto-scroll timer suspension hook (engine wired in Phase 8)

    var autoScrollTimer: Timer?

    func suspendAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    func resumeAutoScrollTimer() {
        if isAutoScrollActive {
            armAutoScrollFallbackTimer()
        }
    }
}
