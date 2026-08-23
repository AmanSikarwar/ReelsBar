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

    /* Reel-by-reel paging: the feed scroller snaps to each reel boundary */
    .reelsbar-snap {
        scroll-snap-type: y mandatory !important;
    }
    .reelsbar-snap > * {
        scroll-snap-align: start !important;
        scroll-snap-stop: always !important;
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
                _feedEl: null,
                _feed() {
                    if (this._feedEl && this._feedEl.isConnected
                        && this._feedEl.scrollHeight > this._feedEl.clientHeight) {
                        return this._feedEl;
                    }
                    this._feedEl = [...document.querySelectorAll('div')]
                        .filter(d => d.scrollHeight > d.clientHeight + 10 && d.clientHeight > 200)
                        .sort((a, b) => b.clientHeight - a.clientHeight)[0]
                        || document.scrollingElement;
                    if (this._feedEl) this._feedEl.classList.add('reelsbar-snap');
                    return this._feedEl;
                },
                _currentItem(feed) {
                    // Climb from the viewport center (or visible video) to a
                    // direct child of the feed — that child is one reel.
                    let node = document.elementFromPoint(window.innerWidth / 2, window.innerHeight / 2);
                    if (!node || node.parentElement !== feed) {
                        if (!node) {
                            const video = [...document.querySelectorAll('video')]
                                .find(v => v.getBoundingClientRect().height > 0);
                            node = video;
                        }
                        while (node && node.parentElement !== feed) node = node.parentElement;
                    }
                    return node && node.parentElement === feed ? node : null;
                },
                _scrollFeed(delta) {
                    const feed = this._feed();
                    if (!feed) return;
                    const item = this._currentItem(feed);
                    const target = item
                        ? (delta > 0 ? item.nextElementSibling : item.previousElementSibling)
                        : null;
                    if (target) {
                        // Land exactly on the next reel's top edge.
                        const top = target.getBoundingClientRect().top
                                  - feed.getBoundingClientRect().top + feed.scrollTop;
                        feed.scrollTo({ top, behavior: 'smooth' });
                    } else {
                        feed.scrollBy({ top: delta, behavior: 'smooth' });
                    }
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
                    this._observer = new MutationObserver(() => {
                        this.applyMuted();
                        if (!this._feedEl || !this._feedEl.isConnected) this._feed();
                    });
                    this._observer.observe(document.body, { childList: true, subtree: true });
                },
                postEditing() {
                    try {
                        window.webkit.messageHandlers.reelsbar.postMessage(
                            { type: 'editing', value: this.isEditing() });
                    } catch (e) {}
                }
            };
            window.__reelsbar.applyMuted();
            window.__reelsbar.observe();
            window.__reelsbar._feed();
            window.__reelsbar.postEditing();
            // Track field focus so native keys never eat login-form typing.
            ['focusin', 'focusout'].forEach(t =>
                document.addEventListener(t, () => window.__reelsbar.postEditing(), true));
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
