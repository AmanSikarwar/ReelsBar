import Foundation
import WebKit

enum ReelsUserScript {
    /// CSS that strips Instagram's non-video chrome so the reel fills the panel.
    static let css = """
    /* Global reset of Instagram padding so the feed spans the full panel */
    html, body {
        margin: 0 !important;
        padding: 0 !important;
        overflow: hidden !important;
        background: #000 !important;
    }

    /* Top header / banner, bottom nav bars, side columns */
    header, nav, footer,
    [role="banner"], [role="navigation"], [role="contentinfo"],
    [aria-label="Navigation"],
    /* Search overlays and dialogs that are not the login flow */
    [role="dialog"]:not([data-reelsbar-keep]),
    /* "Get the app" / App Store promotion blocks */
    a[href*="apps.apple.com"],
    a[href*="play.google.com"],
    div[class*="LoginButton"],
    div[class*="download"],
    /* Story tray and suggestion rails above the feed */
    ul[class*="Stories"],
    section[class*="Suggestions"] {
        display: none !important;
    }

    /* Main article should fill the viewport edge to edge */
    main, article, [role="main"] {
        margin: 0 !important;
        padding: 0 !important;
        width: 100% !important;
        max-width: 100% !important;
    }

    /* The reels feed scroller: full-bleed, vertical paging */
    div[style*="overflow"], div[data-visualcompletion],
    div[class*="Scroll"] {
        max-width: 100% !important;
    }

    video {
        object-fit: contain !important;
    }
    """

    static func inject(into contentController: WKUserContentController) {
        let source = """
        (function() {
            const style = document.createElement('style');
            style.id = 'reelsbar-cleanup';
            style.textContent = \(rawCSSLiteral);
            document.head.appendChild(style);

            // Audio bridge: ReelsBar controls video muting from native code.
            window.__reelsbar = {
                muted: true,
                applyMuted() {
                    document.querySelectorAll('video').forEach(v => {
                        v.muted = this.muted;
                        if (this.muted) v.volume = 0;
                    });
                    return this.muted;
                },
                setMuted(m) { this.muted = !!m; return this.applyMuted(); },
                _autoScroll: false,
                setAutoScroll(on) {
                    this._autoScroll = !!on;
                    if (this._autoScroll) this._watchVideoEnds();
                },
                _watchVideoEnds() {
                    if (this._endedHook) return;
                    // 'ended' does not bubble, so listen in the capture phase.
                    this._endedHook = (ev) => {
                        if (!this._autoScroll || !(ev.target instanceof HTMLVideoElement)) return;
                        try {
                            window.webkit.messageHandlers.reelsbar.postMessage('videoEnded');
                        } catch (e) {}
                        this.scrollNext();
                    };
                    document.addEventListener('ended', this._endedHook, true);
                },
                pauseAll() {
                    document.querySelectorAll('video').forEach(v => v.pause());
                },
                resumeActive() {
                    // Resume only the video currently filling the viewport.
                    const videos = [...document.querySelectorAll('video')];
                    const visible = videos.find(v => {
                        const r = v.getBoundingClientRect();
                        return r.height > 0 && r.bottom > window.innerHeight * 0.5 && r.top < window.innerHeight * 0.5;
                    });
                    if (visible) visible.play().catch(() => {});
                },
                isEditing() {
                    const el = document.activeElement;
                    return !!el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable);
                },
                togglePlay() {
                    const videos = [...document.querySelectorAll('video')];
                    const visible = videos.find(v => v.getBoundingClientRect().height > 0);
                    if (!visible) return;
                    if (visible.paused) visible.play().catch(() => {}); else visible.pause();
                },
                scrollNext() {
                    this._scrollFeed(window.innerHeight);
                },
                scrollPrev() {
                    this._scrollFeed(-window.innerHeight);
                },
                _scrollFeed(delta) {
                    // Find the tallest scrollable ancestor of the video feed.
                    const scrollers = [...document.querySelectorAll('div')]
                        .filter(d => d.scrollHeight > d.clientHeight + 10 && d.clientHeight > 200)
                        .sort((a, b) => b.clientHeight - a.clientHeight);
                    const feed = scrollers[0] || document.scrollingElement;
                    if (feed) feed.scrollBy({ top: delta, behavior: 'smooth' });
                },
                like() {
                    // Best-effort: click the "Like" button on the visible reel.
                    const buttons = [...document.querySelectorAll('svg[aria-label], button')];
                    const like = buttons.find(b => (b.getAttribute('aria-label') || '').toLowerCase() === 'like'
                                                    || (b.closest('[role="button"]')?.getAttribute('aria-label') || '').toLowerCase() === 'like');
                    (like?.closest('[role="button"]') || like)?.dispatchEvent(
                        new MouseEvent('click', { bubbles: true, cancelable: true }));
                },
                // Keep newly-attached video elements in the current mute state.
                observe() {
                    if (this._observer) return;
                    this._observer = new MutationObserver(() => this.applyMuted());
                    this._observer.observe(document.body, { childList: true, subtree: true });
                }
            };
            window.__reelsbar.applyMuted();
            window.__reelsbar.observe();
        })();
        """
        let script = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        contentController.addUserScript(script)
    }

    /// The CSS as a JS string literal.
    private static var rawCSSLiteral: String {
        let data = css.data(using: .utf8)!
        return String(data: data.base64EncodedData(), encoding: .utf8).map { "atob(\"\($0)\")" } ?? "\"\""
    }
}
