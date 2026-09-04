# ReelsBar

A lightweight macOS menu bar app for browsing Instagram Reels in a mobile-sized panel — no browser window, no Dock icon. Click the status bar icon (or press **⌘⇧R** from anywhere) and a 375×667 fullscreen reel panel drops down from the menu bar with a full-bleed Reels feed.

## Features

- **Menu bar popover** — native `NSStatusItem` and `NSPopover`; opens in a 375 × 667 fullscreen reel viewport.
- **Reel mode** — enabled by default; press `F` on the Reels tab to restore the 375 × 812 Instagram panel, and press `F` again to return to the 375 × 667 reel viewport.
- **Mobile web view** — WKWebView loading `instagram.com/reels` with an iPhone Safari User-Agent, so Instagram serves its vertical mobile interface.
- **Instagram UI preserved** — injected CSS hides only Instagram's install-app links.
- **Muted by default** — playback always starts silent (including after reloads and SPA navigations); toggle audio from the panel's speaker button or the `M` key. The state survives hide/show cycles.
- **Keyboard driven** — global and local shortcuts (see table below); letter-key actions are suppressed while you're typing in Instagram's login form.
- **Reel-by-reel scrolling** — a deliberate vertical trackpad gesture or mouse-wheel notch advances exactly one reel; momentum is absorbed instead of leaving the feed between videos.
- **Auto-scroll engine** — advances to the next reel when the current video emits its `ended` event (native owns the advance, exactly once), with a 30-second fallback timer for stalled/looping playback. An "Auto" badge shows on the panel while enabled.
- **Battery friendly** — when the panel closes or the app deactivates, all videos pause, audio is muted, and timers are suspended. Idle CPU with the panel closed measures ~0%.
- **Agent app** — `LSUIElement` is enabled, so ReelsBar runs entirely from the menu bar with no Dock icon or App Switcher entry. Left-click the icon (or ⌘⇧R) to toggle; right-click (or Ctrl-click) for Show/Hide and Quit.

## Keyboard shortcuts

| Shortcut | Scope | Action |
| --- | --- | --- |
| ⌘⇧R | Global (any app) | Show / hide the panel |
| ↑ / ↓ | Panel | Previous / next reel |
| Space | Panel | Play / pause current video |
| M | Panel | Mute / unmute |
| A | Panel | Toggle auto-scroll |
| F | Reels tab | Toggle reel-only 9:16 mode and hide Instagram's bottom bar |
| L, L | Panel | Like the active reel: first press arms, second press (same reel, within ~0.5s) likes; press L again to unlike |

## Getting started

### Requirements

- macOS 27 or later
- Xcode with the macOS 27 SDK

### First launch

1. Build and run (below). The ReelsBar icon appears in your menu bar.
2. Click the icon — Instagram's **login page** loads inside the panel. Log in once; the session is stored in the web view's persistent data store, so you stay logged in across launches.
3. Playback starts muted. Unmute with the speaker button or `M`.

### Build & run with Xcode

```bash
open ReelsBar.xcodeproj   # then ⌘R with the ReelsBar scheme
```

### Build & run from the CLI

```bash
xcodebuild -project ReelsBar.xcodeproj -scheme ReelsBar -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/ReelsBar-*/Build/Products/Debug/ReelsBar.app
```

## Project structure

| File | Role |
| --- | --- |
| `ReelsBar/ReelsBarApp.swift` | App entry: installs the AppKit delegate for the agent app. |
| `ReelsBar/AppDelegate.swift` | Owns the status item, popover, global hotkey, and panel lifecycle. |
| `ReelsBar/AppModel.swift` | Central `@Observable` state: mute, auto-scroll, reel mode, local keyboard actions, and fallback timer. |
| `ReelsBar/ReelsBarPanel.swift` | The fullscreen reel panel: web view plus overlay controls (mute button, auto-scroll badge). |
| `ReelsBar/ReelsWebView.swift` | `NSViewRepresentable` WKWebView: iPhone UA, Reels URL, navigation delegate, script-message handler. |
| `ReelsBar/ReelsUserScript.swift` | Injected JavaScript/CSS: DOM cleanup, `window.__reelsbar` bridge (mute, scroll, play, like, ended events). |
| `ReelsBar/HotkeyManager.swift` | Carbon `RegisterEventHotKey` for the system-wide ⌘⇧R toggle. |

The native ↔ web boundary is the `window.__reelsbar` bridge: native code calls its methods via `evaluateJavaScript`, and the page reports video `ended` events back through a `webkit.messageHandlers.reelsbar` script message.

## Security & privacy

- **App Sandbox** is enabled with only `com.apple.security.network.client` (outgoing connections); no file, camera, or microphone access. Batch loading is purely in-page (no synthetic input events, which the sandbox would deny).
- The app ships no analytics and stores nothing outside the sandboxed web view data store (Instagram cookies/session).
- Developed with ad-hoc signing ("Sign to Run Locally"); re-sign with a Developer ID certificate for distribution.

## Known limitations

- Instagram's DOM is undocumented and changes frequently. The CSS selectors, the like-button lookup, and the feed-scroller heuristics in `ReelsUserScript.swift` are best-effort and may need retuning if Instagram updates its web client.
- The like action (`L`, `L`) simulates a click on the visible reel's Like button: first press arms, second press on the same reel confirms; press `L` again to unlike. It can't bypass Instagram's login walls or bot detection.
- WKWebView blocks unmuted autoplay, which is why playback always starts silent — this doubles as the mute-by-default policy.
