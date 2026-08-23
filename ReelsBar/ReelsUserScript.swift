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
