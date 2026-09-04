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

    /* Snap assist: landings computed in JS target video tops, so declare
       the same snap points to the page. Proximity (not mandatory) only
       tidies residual drift — it never hijacks gestures or fights jumps. */
    html.reelsbar-reel-mode .reelsbar-reel-feed {
        scroll-snap-type: y proximity !important;
    }

    html.reelsbar-reel-mode .reelsbar-reel-feed video {
        scroll-snap-align: start !important;
    }

    html.reelsbar-reel-mode .reelsbar-reel-feed {
        height: 100% !important;
        min-height: 100% !important;
        max-height: 100% !important;
        padding-bottom: 0 !important;
    }

    /* Main column should fill the narrow panel edge to edge */
    main, [role="main"] {
        margin: 0 !important;
        padding: 0 !important;
        width: 100% !important;
        max-width: 100% !important;
    }

    /* Narrow only the marked reel scroller/item, not every scrollable div
       on the page (the old broad selector broke login and dialogs). */
    html.reelsbar-reel-mode .reelsbar-reel-feed {
        max-width: 100% !important;
    }

    video {
        object-fit: contain !important;
    }

    /* Full-bleed active reel in reel mode. */
    html.reelsbar-reel-mode .reelsbar-reel-feed video {
        object-fit: cover !important;
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
                    try {
                        sessionStorage.setItem('reelsbarReelMode', this._reelMode ? '1' : '0');
                    } catch (e) {}
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
                    const video = this._activeVideo();
                    if (!video) return;
                    const feed = this._scrollParent(video);
                    if (!feed) return;
                    document.querySelectorAll('.reelsbar-reel-feed').forEach(element =>
                        element.classList.remove('reelsbar-reel-feed'));
                    if (feed === document.scrollingElement) {
                        // Document-scrolled layout: size the active reel item
                        // itself so the 9:16 CSS still has a target.
                        const item = video.closest('article') || this._reelItem(video, document.body);
                        if (item) item.classList.add('reelsbar-reel-feed');
                        return;
                    }
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
                    // Only report: native owns advancement (videoDidEnd),
                    // so ended -> advance happens exactly once.
                    this._endedHook = (ev) => {
                        if (!this._autoScroll || !(ev.target instanceof HTMLVideoElement)) return;
                        try {
                            window.webkit.messageHandlers.reelsbar.postMessage('videoEnded');
                        } catch (e) {}
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
                // Reel advance is an *instant* position jump to the adjacent
                // video's top, driven by live geometry. Instant (never
                // smooth): Instagram re-mounts videos mid-scroll, which
                // aborts smooth animations and strands the page between
                // reels. Synthetic touch swipes were tried and removed —
                // the page only advances on trusted (native) scrolling.
                scrollNext() {
                    this._jump(1);
                },
                scrollPrev() {
                    this._jump(-1);
                },
                _jump(direction) {
                    if (this._jumping) return;
                    this._pendingLike = null;
                    const videos = this._videos();
                    const current = this._activeVideo(videos);
                    if (!current) {
                        console.log('[reelsbar] jump: no active video, v=' + videos.length);
                        return;
                    }
                    const here = current.getBoundingClientRect();
                    const center = here.top + here.height / 2;
                    const target = videos
                        .filter(video => {
                            const rect = video.getBoundingClientRect();
                            const vc = rect.top + rect.height / 2;
                            return direction > 0 ? vc > center + 1 : vc < center - 1;
                        })
                        .sort((a, b) => {
                            const da = Math.abs(a.getBoundingClientRect().top
                                + a.getBoundingClientRect().height / 2 - center);
                            const db = Math.abs(b.getBoundingClientRect().top
                                + b.getBoundingClientRect().height / 2 - center);
                            return da - db;
                        })[0];
                    if (!target) {
                        console.log('[reelsbar] jump: no adjacent video dir=' + direction);
                        return;
                    }
                    this._jumping = true;
                    const snap = () => {
                        if (!target.isConnected) return;
                        const t = target.getBoundingClientRect();
                        const feed = this._scrollParent(target);
                        // Force truly instant jumps: the page's CSS may set
                        // scroll-behavior:smooth, which would turn every
                        // scrollTo/scrollTop into an abortable animation.
                        [document.documentElement, document.body, feed].forEach(el => {
                            if (el && el.style) {
                                el.style.setProperty('scroll-behavior', 'auto', 'important');
                            }
                        });
                        if (feed === document.scrollingElement) {
                            window.scrollTo(0, window.scrollY + t.top);
                        } else {
                            feed.scrollTop += t.top - feed.getBoundingClientRect().top;
                        }
                    };
                    snap();
                    console.log('[reelsbar] jump dir=' + direction);
                    // Re-verify: re-mounts or the page's own snap logic can
                    // undo the landing shortly after. Re-snap while the old
                    // video still dominates, then release.
                    let checks = 0;
                    const verifyTimer = setInterval(() => {
                        checks += 1;
                        let settled = true;
                        try {
                            if (this._activeVideo() === current && target.isConnected) {
                                snap();
                                settled = false;
                                console.log('[reelsbar] jump corrected dir='
                                    + direction + ' pass=' + checks);
                            }
                        } catch (e) { settled = true; }
                        if (settled || checks >= 3) {
                            clearInterval(verifyTimer);
                            this._jumping = false;
                        }
                    }, 250);
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
                // Throttled: Instagram mutates constantly during playback, so
                // applying on every mutation would churn CPU.
                observe() {
                    if (this._observer) return;
                    this._observer = new MutationObserver(() => {
                        if (this._mutedApplyQueued) return;
                        this._mutedApplyQueued = true;
                        const flush = () => {
                            this._mutedApplyQueued = false;
                            this.applyMuted();
                            if (this._reelMode) {
                                this._markBottomNavigation();
                                this._markReelFeed();
                            }
                        };
                        if (typeof requestAnimationFrame !== 'undefined') {
                            requestAnimationFrame(flush);
                        } else {
                            setTimeout(flush, 100);
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
            window.__reelsbar.applyMuted();
            window.__reelsbar.observe();
            // Restore the persisted reel-mode choice (default on) instead of
            // forcing reel mode: a reload must not desync from native state.
            try {
                const saved = sessionStorage.getItem('reelsbarReelMode');
                window.__reelsbar.setReelMode(saved === null ? true : saved === '1');
            } catch (e) {
                window.__reelsbar.setReelMode(true);
            }
            window.__reelsbar.postEditing();
            window.__reelsbar.postRoute();
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
            // NOTE: the mirror is async (postMessage -> @MainActor), so a
            // keystroke landing in the same runloop as a focus change can
            // still race. Refresh on every focus/blur/input/key event to
            // keep the window as tight as possible.
            ['focusin', 'focusout', 'focus', 'blur', 'input'].forEach(t =>
                document.addEventListener(t, () => window.__reelsbar.postEditing(), true));
            document.addEventListener('keydown',
                () => window.__reelsbar.postEditing(), true);

            // Forward page console output to native for diagnostics.
            // Filtered to our own prefix: Instagram logs verbosely and
            // would otherwise flood the script-message bridge.
            const nativeLog = (...args) => {
                const text = args.map(a => {
                    try { return typeof a === 'object' ? JSON.stringify(a) : String(a); }
                    catch (e) { return '?'; }
                }).join(' ').slice(0, 500);
                if (!text.includes('[reelsbar]')) return;
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
