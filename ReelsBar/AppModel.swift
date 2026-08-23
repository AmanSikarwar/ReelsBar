import SwiftUI
import WebKit

@Observable
@MainActor
final class AppModel {
    var isMuted = true
    var isAutoScrollActive = false
    var isPanelActive = false
    /// Mirrors DOM focus state so the key monitor can guard synchronously.
    var isPageEditing = false

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

    // MARK: - Keyboard actions

    func scrollNext() {
        runJS("window.__reelsbar && window.__reelsbar.scrollNext()")
    }

    func scrollPrev() {
        runJS("window.__reelsbar && window.__reelsbar.scrollPrev()")
    }

    func togglePlay() {
        runJS("window.__reelsbar && window.__reelsbar.togglePlay()")
    }

    func like() {
        runJS("window.__reelsbar && window.__reelsbar.like()")
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
        print("[ReelsBar] panel deactivated")
        runJS("window.__reelsbar && (window.__reelsbar.pauseAll(), window.__reelsbar.setMuted(true))")
        suspendAutoScrollTimer()
        audioWatchdog?.invalidate()
        audioWatchdog = nil
    }

    /// Restore readiness and the user's prior mute choice when visible again.
    func handlePanelActivated() {
        guard !isPanelActive, webView != nil, NSApp.isActive else { return }
        isPanelActive = true
        print("[ReelsBar] panel activated")
        runJS("window.__reelsbar && (window.__reelsbar.setMuted(\(isMuted)), window.__reelsbar.resumeActive())")
        resumeAutoScrollTimer()
        startAudioWatchdog()
    }

    /// Re-assert the audio state every second while visible: Instagram's own
    /// scripts reset `video.muted` when they re-render, which would otherwise
    /// fight the native toggle.
    private var audioWatchdog: Timer?

    private func startAudioWatchdog() {
        audioWatchdog?.invalidate()
        audioWatchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runJS("window.__reelsbar && window.__reelsbar.applyMuted()")
            }
        }
    }

    // MARK: - Local keyboard monitoring (active window only)

    private var localKeyMonitor: Any?

    func startKeyboardMonitoring() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isPanelActive else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard !flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return event }
                let editing = self.isPageEditing
                if [0, 37, 46, 49, 125, 126].contains(event.keyCode) {
                    print("[ReelsBar] key \(event.keyCode) editing=\(editing)")
                }
                switch event.keyCode {
                case 125: // Down — next reel (swallow the page's line-scroll)
                    guard !editing else { return event }
                    self.scrollNext()
                    return nil
                case 126: // Up — previous reel
                    guard !editing else { return event }
                    self.scrollPrev()
                    return nil
                case 49: // Space — play/pause (swallow the page's space-scroll)
                    guard !editing else { return event }
                    self.togglePlay()
                    return nil
                case 46: if !editing { self.toggleMute() }        // M
                case 0:  if !editing { self.toggleAutoScroll() }  // A
                case 37: if !editing { self.like() }              // L
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
