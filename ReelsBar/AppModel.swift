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

    func handleLikeKey() {
        runJS("window.__reelsbar && window.__reelsbar.handleLikeKey()")
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
        guard !isPanelActive else { return }
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

    // MARK: - Local input monitoring (active panel only)

    private var localKeyMonitor: Any?
    private var localScrollMonitor: Any?
    private var scrollGestureHandled = false
    private var scrollGestureResetTask: Task<Void, Never>?

    func startInputMonitoring() {
        if localKeyMonitor == nil {
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
                    case 46: // M
                        guard !editing else { return event }
                        self.toggleMute()
                        return nil
                    case 0: // A
                        guard !editing else { return event }
                        self.toggleAutoScroll()
                        return nil
                    case 37: // L
                        guard !editing else { return event }
                        guard !event.isARepeat else { return nil }
                        self.handleLikeKey()
                        return nil
                    default: break
                    }
                    return event
                }
            }
        }
        if localScrollMonitor == nil {
            assert(Self.scrollDirection(deltaX: 0, deltaY: -1) == 1)
            assert(Self.scrollDirection(deltaX: 0, deltaY: 1) == -1)
            localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleScrollWheel(event) ?? event
                }
            }
        }
    }

    private static func scrollDirection(deltaX: Double, deltaY: Double) -> Int? {
        guard abs(deltaY) >= 0.1, abs(deltaY) > abs(deltaX) else { return nil }
        return deltaY < 0 ? 1 : -1
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard isPanelActive else { return event }
        guard let direction = Self.scrollDirection(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY
        ) else { return event }

        if !scrollGestureHandled {
            scrollGestureHandled = true
            direction > 0 ? scrollNext() : scrollPrev()
        }
        scrollGestureResetTask?.cancel()
        scrollGestureResetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.scrollGestureHandled = false
        }
        return nil
    }

    // MARK: - Auto-scroll timer

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
