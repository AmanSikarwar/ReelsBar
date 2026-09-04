import SwiftUI
import WebKit

@Observable
@MainActor
final class AppModel {
    static let panelSize = CGSize(width: 375, height: 812)
    static let reelSize = CGSize(width: 375, height: 667)

    var isMuted = true
    var isAutoScrollActive = false
    var isPanelActive = false
    var isReelsTab = false
    var isReelMode = true
    var reelModeDidChange: ((Bool) -> Void)?
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
        // Manual advancement restarts the stall window.
        lastVideoEndedAt = Date()
        runJS("window.__reelsbar && window.__reelsbar.scrollNext()")
    }

    func scrollPrev() {
        lastVideoEndedAt = Date()
        runJS("window.__reelsbar && window.__reelsbar.scrollPrev()")
    }

    func togglePlay() {
        runJS("window.__reelsbar && window.__reelsbar.togglePlay()")
    }

    func handleLikeKey() {
        // Double-press arm/confirm (see _likeKeyAction): surface the result
        // so arm vs like vs unlike vs missing-control is diagnosable.
        webView?.evaluateJavaScript(
            "window.__reelsbar && window.__reelsbar.handleLikeKey()"
        ) { result, error in
            if let error {
                print("[ReelsBar] like error: \(error.localizedDescription)")
            } else {
                print("[ReelsBar] like key: \(result ?? "nil")")
            }
        }
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

    func setReelsTab(_ isReels: Bool) {
        isReelsTab = isReels
        setReelMode(isReels)
    }

    func toggleReelMode() {
        guard isReelsTab else { return }
        setReelMode(!isReelMode)
    }

    private func setReelMode(_ enabled: Bool) {
        guard enabled != isReelMode else { return }
        isReelMode = enabled
        runJS("window.__reelsbar && window.__reelsbar.setReelMode(\(enabled))")
        reelModeDidChange?(enabled)
    }

    // MARK: - Auto-scroll engine

    /// How long without a native `ended` event before the fallback timer advances.
    static let autoScrollFallbackInterval: TimeInterval = 30

    private(set) var lastVideoEndedAt: Date?

    /// Single owner of ended-driven advancement (the page only reports;
    /// see `_watchVideoEnds`). Falls back to the stall timer for looping
    /// videos that never emit `ended`.
    func videoDidEnd() {
        lastVideoEndedAt = Date()
        guard isAutoScrollActive, isPanelActive else { return }
        scrollNext()
    }

    private func armAutoScrollFallbackTimer() {
        suspendAutoScrollTimer()
        guard isPanelActive else { return }
        let timer = Timer(timeInterval: Self.autoScrollFallbackInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isAutoScrollActive, self.isPanelActive else { return }
                let stalled = self.lastVideoEndedAt.map { Date().timeIntervalSince($0) > Self.autoScrollFallbackInterval } ?? true
                if stalled { self.scrollNext() }
            }
        }
        autoScrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
        scrollGestureResetTask?.cancel()
        finishScrollGesture()
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
    private var accumulatedScrollDeltaY = 0.0
    private var scrollGestureResetTask: Task<Void, Never>?
    private static let preciseScrollThreshold = 24.0

    func startInputMonitoring() {
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.isPanelActive else { return event }
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    guard !flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return event }
                    let editing = self.isPageEditing
                    if [0, 3, 37, 46, 49, 125, 126].contains(event.keyCode) {
                        print("[ReelsBar] key \(event.keyCode) editing=\(editing)")
                    }
                    switch event.keyCode {
                    case 125: // Down — next reel
                        guard !editing, self.isReelsTab else { return event }
                        self.scrollNext()
                        return nil
                    case 126: // Up — previous reel
                        guard !editing, self.isReelsTab else { return event }
                        self.scrollPrev()
                        return nil
                    case 49: // Space — play/pause (swallow the page's space-scroll)
                        guard !editing, self.isReelsTab else { return event }
                        guard !event.isARepeat else { return nil }
                        self.togglePlay()
                        return nil
                    case 46: // M
                        guard !editing, self.isReelsTab else { return event }
                        guard !event.isARepeat else { return nil }
                        self.toggleMute()
                        return nil
                    case 0: // A
                        guard !editing, self.isReelsTab else { return event }
                        guard !event.isARepeat else { return nil }
                        self.toggleAutoScroll()
                        return nil
                    case 3: // F — reel-only mode
                        guard !editing, self.isReelsTab else { return event }
                        guard !event.isARepeat else { return nil }
                        self.toggleReelMode()
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
            localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleScrollWheel(event) ?? event
                }
            }
        }
    }

    /// Maps accumulated scroll delta to reel direction. `inverted` mirrors
    /// `NSEvent.isDirectionInvertedFromDevice` so "push content up" means
    /// next reel regardless of the user's natural-scroll setting.
    private static func scrollDirection(
        accumulatedDeltaY: Double, precise: Bool, inverted: Bool
    ) -> Int? {
        let threshold = precise ? preciseScrollThreshold : 1
        let adjusted = inverted ? -accumulatedDeltaY : accumulatedDeltaY
        guard abs(adjusted) >= threshold else { return nil }
        return adjusted < 0 ? 1 : -1
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard isPanelActive else { return event }
        // Off the Reels tab (e.g. login page) the page owns scrolling.
        guard isReelsTab else { return event }
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }

        if !scrollGestureHandled {
            accumulatedScrollDeltaY += event.scrollingDeltaY
            if let direction = Self.scrollDirection(
                accumulatedDeltaY: accumulatedScrollDeltaY,
                precise: event.hasPreciseScrollingDeltas,
                inverted: event.isDirectionInvertedFromDevice
            ) {
                scrollGestureHandled = true
                direction > 0 ? scrollNext() : scrollPrev()
            }
        }
        scheduleScrollGestureReset(for: event)
        return nil
    }

    private func scheduleScrollGestureReset(for event: NSEvent) {
        scrollGestureResetTask?.cancel()
        if event.momentumPhase.contains(.ended)
            || event.momentumPhase.contains(.cancelled) {
            finishScrollGesture()
            return
        }
        scrollGestureResetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.finishScrollGesture()
        }
    }

    private func finishScrollGesture() {
        scrollGestureHandled = false
        accumulatedScrollDeltaY = 0
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
