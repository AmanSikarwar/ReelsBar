import Foundation
import WebKit

enum ReelsUserScript {
    /// CSS that preserves Instagram's chrome and hides only install-app links.
    static let css = """
    /* Global reset of Instagram padding so the feed spans the full panel */
    html, body {
        margin: 0 !important;
        padding: 0 !important;
        background: #000 !important;
    }

    /* Hide only Instagram's install-app links. */
    a[href*="apps.apple.com"],
    a[href*="play.google.com"] {
        display: none !important;
    }

    /* F toggles this class for a reel-only 9:16 viewport. */
    html.reelsbar-reel-mode .reelsbar-bottom-nav {
        display: none !important;
    }

    html.reelsbar-reel-mode .reelsbar-reel-feed {
        height: 100% !important;
        min-height: 100% !important;
        max-height: 100% !important;
        padding-bottom: 0 !important;
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
                    // Never touch `volume` — muting alone silences, and stale
                    // volume=0 would keep the feed silent after unmute.
                    document.querySelectorAll('video').forEach(v => { v.muted = this.muted; });
                    return this.muted;
                },
                setMuted(m) { this.muted = !!m; console.log('[reelsbar] setMuted', m); return this.applyMuted(); },
                _autoScroll: false,
                setAutoScroll(on) {
                    this._autoScroll = !!on;
                    if (this._autoScroll) this._watchVideoEnds();
                },
                _reelMode: true,
                setReelMode(on) {
                    this._reelMode = !!on;
                    document.documentElement.classList.toggle(
                        'reelsbar-reel-mode', this._reelMode);
                    if (this._reelMode) {
                        this._markBottomNavigation();
                        this._markReelFeed();
                    } else {
                        document.querySelectorAll('.reelsbar-bottom-nav').forEach(element =>
                            element.classList.remove('reelsbar-bottom-nav'));
                        document.querySelectorAll('.reelsbar-reel-feed').forEach(element =>
                            element.classList.remove('reelsbar-reel-feed'));
                    }
                },
                _markReelFeed() {
                    const feed = this._scrollParent(this._activeVideo());
                    if (!feed || feed === document.scrollingElement) return;
                    document.querySelectorAll('.reelsbar-reel-feed').forEach(element =>
                        element.classList.remove('reelsbar-reel-feed'));
                    feed.classList.add('reelsbar-reel-feed');
                },
                _markBottomNavigation() {
                    const semantic = 'nav, footer, [role="navigation"], [role="tablist"], '
                        + '[aria-label*="navigation" i], [aria-label*="menu" i]';
                    const bottom = window.innerHeight - 2;
                    document.querySelectorAll('.reelsbar-bottom-nav').forEach(element =>
                        element.classList.remove('reelsbar-bottom-nav'));
                    const isBottomBar = (element) => {
                        const rect = element.getBoundingClientRect();
                        return rect.width >= window.innerWidth * 0.85
                            && rect.height >= 40 && rect.height <= 100
                            && rect.top >= window.innerHeight * 0.65
                            && rect.bottom >= bottom;
                    };
                    const markBarAndContainer = (element) => {
                        for (let current = element; current; current = current.parentElement) {
                            const rect = current.getBoundingClientRect();
                            if (rect.width < window.innerWidth * 0.85
                                || rect.height < 40 || rect.height > 120
                                || rect.top < window.innerHeight * 0.65
                                || rect.bottom < bottom) break;
                            current.classList.add('reelsbar-bottom-nav');
                        }
                    };
                    const semanticBars = [...document.querySelectorAll(semantic)]
                        .filter(isBottomBar);
                    if (semanticBars.length) {
                        document.querySelectorAll('.reelsbar-bottom-nav').forEach(element =>
                            element.classList.remove('reelsbar-bottom-nav'));
                        semanticBars.forEach(markBarAndContainer);
                        return;
                    }
                    const bar = [...document.querySelectorAll('div')]
                        .filter(element => isBottomBar(element)
                            && element.querySelectorAll('a, button, [role="button"], [role="link"]').length >= 3)
                        .sort((a, b) => b.getBoundingClientRect().height - a.getBoundingClientRect().height)[0];
                    if (bar) {
                        document.querySelectorAll('.reelsbar-bottom-nav').forEach(element =>
                            element.classList.remove('reelsbar-bottom-nav'));
                        markBarAndContainer(bar);
                    }
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
                    const visible = this._activeVideo();
                    if (visible) visible.play().catch(() => {});
                },
                isEditing() {
                    const el = document.activeElement;
                    return !!el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable);
                },
                togglePlay() {
                    const visible = this._activeVideo();
                    console.log('[reelsbar] togglePlay, visible:', !!visible);
                    if (!visible) return;
                    if (visible.paused) visible.play().catch(() => {}); else visible.pause();
                },
                scrollNext() {
                    this._scrollFeed(1);
                },
                scrollPrev() {
                    this._scrollFeed(-1);
                },
                _videos() {
                    return [...document.querySelectorAll('video')]
                        .filter(v => v.getBoundingClientRect().height > 0)
                        .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
                },
                _activeVideo(videos = this._videos()) {
                    let active = null;
                    let visibleHeight = 0;
                    videos.forEach(video => {
                        const rect = video.getBoundingClientRect();
                        const height = Math.max(0,
                            Math.min(rect.bottom, window.innerHeight) - Math.max(rect.top, 0));
                        if (height > visibleHeight) {
                            active = video;
                            visibleHeight = height;
                        }
                    });
                    return active;
                },
                _scrollParent(element) {
                    for (let parent = element?.parentElement; parent; parent = parent.parentElement) {
                        const overflow = getComputedStyle(parent).overflowY;
                        if (parent.scrollHeight > parent.clientHeight + 10
                            && /auto|scroll|overlay/.test(overflow)) return parent;
                    }
                    return document.scrollingElement;
                },
                _reelItem(video, feed) {
                    let item = video;
                    while (item?.parentElement && item.parentElement !== feed) {
                        item = item.parentElement;
                    }
                    return item?.parentElement === feed ? item : video;
                },
                _adjacentVideo(direction, videos = this._videos(), current = this._activeVideo(videos)) {
                    if (!current) return null;
                    const currentRect = current.getBoundingClientRect();
                    const currentCenter = currentRect.top + currentRect.height / 2;
                    return videos
                        .filter(video => {
                            const rect = video.getBoundingClientRect();
                            const center = rect.top + rect.height / 2;
                            return direction > 0 ? center > currentCenter + 1 : center < currentCenter - 1;
                        })
                        .sort((a, b) => {
                            const aRect = a.getBoundingClientRect();
                            const bRect = b.getBoundingClientRect();
                            const aDistance = Math.abs(aRect.top + aRect.height / 2 - currentCenter);
                            const bDistance = Math.abs(bRect.top + bRect.height / 2 - currentCenter);
                            return aDistance - bDistance;
                        })[0] || null;
                },
                _resumePendingScroll() {
                    const direction = this._pendingScrollDirection;
                    if (!direction || this._scrolling || !this._adjacentVideo(direction)) return;
                    this._pendingScrollDirection = 0;
                    this._scrollFeed(direction);
                },
                _scrolling: false,
                _pendingScrollDirection: 0,
                _scrollFeed(direction) {
                    if (this._scrolling) return;
                    this._pendingLike = null;
                    const videos = this._videos();
                    const current = this._activeVideo(videos);
                    if (!current) return;
                    const target = this._adjacentVideo(direction, videos, current);
                    const feed = this._scrollParent(current);
                    this._scrolling = true;
                    if (target) {
                        this._pendingScrollDirection = 0;
                        const item = this._reelItem(target, feed);
                        item.scrollIntoView({ behavior: 'smooth', block: 'start' });
                        setTimeout(() => {
                            if (item.isConnected) {
                                const settledFeedTop = feed === document.scrollingElement
                                    ? 0 : feed.getBoundingClientRect().top;
                                feed.scrollTop += item.getBoundingClientRect().top - settledFeedTop;
                            }
                            this._scrolling = false;
                        }, 400);
                    } else {
                        this._pendingScrollDirection = direction;
                        const distance = feed.clientHeight || window.innerHeight;
                        feed.scrollBy({ top: direction * distance, behavior: 'smooth' });
                        setTimeout(() => {
                            this._scrolling = false;
                            this._resumePendingScroll();
                        }, 400);
                        setTimeout(() => {
                            if (direction > 0
                                && this._pendingScrollDirection === direction
                                && !this._adjacentVideo(direction)) {
                                sessionStorage.setItem('reelsbarPendingScroll', String(direction));
                                location.reload();
                            }
                        }, 1200);
                    }
                    console.log('[reelsbar] scroll direction', direction, 'target', !!target);
                },
                // Snapshot of everything native debugging needs to know.
                diag() {
                    const info = (el) => el ? {
                        tag: el.tagName, cls: String(el.className).slice(0, 50),
                        scrollH: el.scrollHeight, clientH: el.clientHeight,
                        kids: el.children.length
                    } : null;
                    const scrollers = [...document.querySelectorAll('div')]
                        .filter(d => d.scrollHeight > d.clientHeight + 10)
                        .slice(0, 5).map(info);
                    const videos = this._videos();
                    const visible = this._activeVideo(videos);
                    return JSON.stringify({
                        url: location.href,
                        viewport: window.innerWidth + 'x' + window.innerHeight,
                        documentScroller: info(document.scrollingElement),
                        scrollerDivs: scrollers,
                        chosenFeed: info(this._scrollParent(visible)),
                        articles: document.querySelectorAll('article').length,
                        videos: videos.length,
                        visibleVideo: visible ? {
                            muted: visible.muted, volume: visible.volume,
                            paused: visible.paused,
                            height: Math.round(visible.getBoundingClientRect().height)
                        } : null
                    });
                },
                _likeLabel(control) {
                    if (!control) return '';
                    const labeled = [control, ...control.querySelectorAll('[aria-label]')];
                    return labeled
                        .map(element => (element.getAttribute('aria-label') || '').trim().toLowerCase())
                        .find(label => label === 'like' || label === 'unlike') || '';
                },
                _likeControl(video) {
                    if (!video) return null;
                    const videoRect = video.getBoundingClientRect();
                    const videoCenter = videoRect.top + videoRect.height / 2;
                    const controls = [...new Set(
                        [...document.querySelectorAll('[aria-label]')]
                            .filter(element => {
                                const label = (element.getAttribute('aria-label') || '').trim().toLowerCase();
                                return label === 'like' || label === 'unlike';
                            })
                            .map(element => element.closest('button, [role="button"]') || element)
                    )].filter(control => {
                        const rect = control.getBoundingClientRect();
                        return rect.width > 0 && rect.height > 0;
                    });
                    return controls.sort((a, b) => {
                        const aRect = a.getBoundingClientRect();
                        const bRect = b.getBoundingClientRect();
                        const aDistance = Math.abs(aRect.top + aRect.height / 2 - videoCenter);
                        const bDistance = Math.abs(bRect.top + bRect.height / 2 - videoCenter);
                        return aDistance - bDistance;
                    })[0] || null;
                },
                _likeKeyAction(isLiked, sameVideo, elapsed) {
                    if (isLiked) return 'unlike';
                    if (sameVideo && elapsed >= 0 && elapsed <= 500) return 'like';
                    return 'arm';
                },
                _pendingLike: null,
                handleLikeKey() {
                    const video = this._activeVideo();
                    const control = this._likeControl(video);
                    if (!video || !control) return 'missing';

                    const now = performance.now();
                    const pending = this._pendingLike;
                    const action = this._likeKeyAction(
                        this._likeLabel(control) === 'unlike',
                        pending?.video === video,
                        now - (pending?.at ?? now)
                    );
                    if (action === 'arm') {
                        this._pendingLike = { video, at: now };
                    } else {
                        this._pendingLike = null;
                        control.click();
                    }
                    console.log('[reelsbar] like key', action);
                    return action;
                },
                // Keep newly-attached video elements in the current mute state.
                observe() {
                    if (this._observer) return;
                    this._observer = new MutationObserver(() => {
                        this.applyMuted();
                        this._resumePendingScroll();
                        if (this._reelMode) {
                            this._markBottomNavigation();
                            this._markReelFeed();
                        }
                    });
                    this._observer.observe(document.body, { childList: true, subtree: true });
                },
                postEditing() {
                    try {
                        window.webkit.messageHandlers.reelsbar.postMessage(
                            { type: 'editing', value: this.isEditing() });
                    } catch (e) {}
                },
                _reelsRoute: null,
                postRoute() {
                    const path = location.pathname;
                    const reels = path === '/reels' || path.startsWith('/reels/');
                    if (reels === this._reelsRoute) return;
                    this._reelsRoute = reels;
                    try {
                        window.webkit.messageHandlers.reelsbar.postMessage(
                            { type: 'route', reels });
                    } catch (e) {}
                }
            };
            window.__reelsbar._pendingScrollDirection =
                Number(sessionStorage.getItem('reelsbarPendingScroll')) || 0;
            sessionStorage.removeItem('reelsbarPendingScroll');
            window.__reelsbar.applyMuted();
            window.__reelsbar.observe();
            window.__reelsbar.setReelMode(true);
            window.__reelsbar.postEditing();
            window.__reelsbar.postRoute();
            setTimeout(() => window.__reelsbar._resumePendingScroll(), 500);
            window.addEventListener('resize', () => {
                if (window.__reelsbar._reelMode) {
                    window.__reelsbar._markBottomNavigation();
                    window.__reelsbar._markReelFeed();
                }
            });
            ['popstate', 'hashchange'].forEach(t =>
                window.addEventListener(t, () => window.__reelsbar.postRoute()));
            ['pushState', 'replaceState'].forEach(method => {
                const original = history[method];
                history[method] = function() {
                    const result = original.apply(this, arguments);
                    window.__reelsbar.postRoute();
                    return result;
                };
            });
            // Track field focus so native keys never eat login-form typing.
            ['focusin', 'focusout'].forEach(t =>
                document.addEventListener(t, () => window.__reelsbar.postEditing(), true));

            // Forward page console output to native for diagnostics.
            const nativeLog = (...args) => {
                const text = args.map(a => {
                    try { return typeof a === 'object' ? JSON.stringify(a) : String(a); }
                    catch (e) { return '?'; }
                }).join(' ').slice(0, 500);
                try {
                    window.webkit.messageHandlers.reelsbar.postMessage({ type: 'log', value: text });
                } catch (e) {}
            };
            ['log', 'warn', 'error'].forEach(k => {
                const orig = console[k].bind(console);
                console[k] = (...a) => { nativeLog(...a); orig(...a); };
            });
            console.assert(window.__reelsbar._likeKeyAction(false, false, 0) === 'arm');
            console.assert(window.__reelsbar._likeKeyAction(false, true, 250) === 'like');
            console.assert(window.__reelsbar._likeKeyAction(true, false, 0) === 'unlike');
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
