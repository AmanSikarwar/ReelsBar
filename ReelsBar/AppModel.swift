import SwiftUI
import WebKit

@Observable
@MainActor
final class AppModel {
    static let panelSize = CGSize(width: 375, height: 812)
    static let reelSize = CGSize(width: 375, height: 667)

    /// Single source for the popover/panel mapping so AppDelegate and
    /// ReelsBarPanel cannot drift apart.
    static func contentSize(forReelMode reelMode: Bool) -> CGSize {
        reelMode ? reelSize : panelSize
    }

    var isMuted = true
    var isAutoScrollActive = false
    var isPanelActive = false
    var isReelsTab = false
    var isReelMode = true
    var reelModeDidChange: ((Bool) -> Void)?
    private var lastNotifiedReelMode: Bool?
    /// Mirrors DOM focus state so the key monitor can guard synchronously.
    var isPageEditing = false

    /// Strong: the web view (and its Instagram session) must survive
    /// SwiftUI view recreations and popover close/open cycles. No cycle:
    /// the Coordinator only holds a weak appModel.
    var webView: WKWebView?

    func runJS(_ js: String) {
        webView?.evaluateJavaScript(js) { _, error in
            if let error {
                print("[ReelsBar] js error: \(error.localizedDescription) :: \(js.prefix(80))")
            }
        }
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
        print("[ReelsBar] scroll next (tab=\(isReelsTab) active=\(isPanelActive))")
        runJS("window.__reelsbar && window.__reelsbar.scrollNext()")
    }

    func scrollPrev() {
        lastVideoEndedAt = Date()
        print("[ReelsBar] scroll prev (tab=\(isReelsTab) active=\(isPanelActive))")
        runJS("window.__reelsbar && window.__reelsbar.scrollPrev()")
    }

    func togglePlay() {
        runJS("window.__reelsbar && window.__reelsbar.togglePlay()")
    }

    /// On-screen feed diagnostics overlay (D). Panel-global like mute so a
    /// stall can be read off the screen on any page.
    func toggleStats() {
        runJS("window.__reelsbar && window.__reelsbar.toggleStats()")
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

    /// Tracks an explicit F toggle so returning to reels doesn't discard it.
    private var reelModeUserOverride = false

    func setReelsTab(_ isReels: Bool) {
        print("[ReelsBar] route reels=\(isReels)")
        isReelsTab = isReels
        if isReels {
            // Entering reels defaults to reel mode, but respect an explicit
            // prior F choice instead of forcing it back on.
            if !reelModeUserOverride {
                setReelMode(true)
            } else {
                enforceReelModePolicy()
            }
        } else {
            setReelMode(false)
        }
    }

    func toggleReelMode() {
        guard isReelsTab else { return }
        reelModeUserOverride = true
        setReelMode(!isReelMode)
    }

    private func setReelMode(_ enabled: Bool) {
        guard enabled != isReelMode else {
            // State unchanged but the observer may never have been told
            // (e.g. popover recreated); sync it without spamming resizes.
            if lastNotifiedReelMode != isReelMode {
                lastNotifiedReelMode = isReelMode
                reelModeDidChange?(isReelMode)
            }
            return
        }
        isReelMode = enabled
        runJS("window.__reelsbar && window.__reelsbar.setReelMode(\(enabled))")
        lastNotifiedReelMode = enabled
        reelModeDidChange?(enabled)
    }

    /// Re-assert the current reel mode after (re)loads and re-activation so
    /// a fresh page context can't desync from native state.
    func enforceReelModePolicy() {
        runJS("window.__reelsbar && window.__reelsbar.setReelMode(\(isReelMode))")
        // Notify only on actual size change; unconditional callbacks caused
        // popover flicker on every navigation/activation.
        guard lastNotifiedReelMode != isReelMode else { return }
        lastNotifiedReelMode = isReelMode
        reelModeDidChange?(isReelMode)
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
                // Tolerance for RunLoop drift + MainActor hop: an exact `>`
                // check can read 29.99s and skip a whole 30s cycle.
                let stalled = self.lastVideoEndedAt.map {
                    Date().timeIntervalSince($0) >= Self.autoScrollFallbackInterval - 0.5
                } ?? true
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
        enforceAutoScrollPolicy()
        enforceReelModePolicy()
    }

    /// Re-assert the native auto-scroll flag so a fresh page context
    /// (which resets `_autoScroll` to false) cannot desync after reloads.
    func enforceAutoScrollPolicy() {
        runJS("window.__reelsbar && window.__reelsbar.setAutoScroll(\(isAutoScrollActive))")
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
        enforceAutoScrollPolicy()
        enforceReelModePolicy()
        resumeAutoScrollTimer()
        startAudioWatchdog()
    }

    /// Re-assert the audio state every second while visible: Instagram's own
    /// scripts reset `video.muted` when they re-render, which would otherwise
    /// fight the native toggle.
    private var audioWatchdog: Timer?

    private func startAudioWatchdog() {
        audioWatchdog?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runJS("window.__reelsbar && window.__reelsbar.applyMuted()")
            }
        }
        audioWatchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Local input monitoring (active panel only)

    // NOTE: wheel/trackpad scrolling intentionally flows through to the
    // page untouched. Reel advancement only sticks when Instagram's own
    // index moves, and that happens solely on trusted gesture input —
    // intercepting the wheel and jumping programmatically gets reverted
    // (yank-back to the tracked reel). One-reel-per-flick paging comes
    // from mandatory scroll-snap CSS injected into the page instead.
    private var localKeyMonitor: Any?

    func startInputMonitoring() {
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.isPanelActive else { return event }
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    guard !flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return event }
                    let editing = self.isPageEditing
                    if [0, 2, 3, 37, 46, 49, 125, 126].contains(event.keyCode) {
                        print("[ReelsBar] key \(event.keyCode) editing=\(editing)")
                    }
                    switch event.keyCode {
                    case 125: // Down — next reel (discrete; holding must not spam the bridge)
                        guard !editing, self.isReelsTab else { return event }
                        guard !event.isARepeat else { return nil }
                        self.scrollNext()
                        return nil
                    case 126: // Up — previous reel (discrete; holding must not spam the bridge)
                        guard !editing, self.isReelsTab else { return event }
                        guard !event.isARepeat else { return nil }
                        self.scrollPrev()
                        return nil
                    case 49: // Space — play/pause (swallow the page's space-scroll)
                        guard !editing, self.isReelsTab else { return event }
                        guard !event.isARepeat else { return nil }
                        self.togglePlay()
                        return nil
                    case 46: // M — global: videos (and the watchdog) exist outside reels
                        guard !editing else { return event }
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
                    case 2: // D — feed stats overlay (diagnostics; panel-global)
                        guard !editing else { return event }
                        guard !event.isARepeat else { return nil }
                        self.toggleStats()
                        return nil
                    case 37: // L — like requires a reels context like every other shortcut.
                        // NOTE: `isPageEditing` mirrors the DOM asynchronously
                        // (postMessage -> @MainActor), so a keystroke in the
                        // same runloop as a focus change can still race. The
                        // page re-posts on focusin/focusout/input/keydown to
                        // keep the window tight; when in doubt we still let
                        // editable text through on the next event once the
                        // mirror lands.
                        guard !editing, self.isReelsTab else { return event }
                        guard !event.isARepeat else { return nil }
                        self.handleLikeKey()
                        return nil
                    default: break
                    }
                    return event
                }
            }
        }
    }


    // MARK: - Auto-scroll timer
    private var autoScrollTimer: Timer?

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
