# ReelsBar

A lightweight macOS menu bar app for browsing Instagram Reels in a mobile-sized panel — no browser window, no Dock icon. Click the status bar icon (or press **⌘⇧R** from anywhere) and a 375×667 floating panel drops down from the menu bar with a full-bleed Reels feed.

## Features

- **Menu bar popover** — `MenuBarExtra` (window style) anchored to a status item; fixed mobile viewport of 375 × 667.
- **Mobile web view** — WKWebView loading `instagram.com/reels` with an iPhone Safari User-Agent, so Instagram serves its vertical mobile interface.
- **Clean feed** — injected CSS strips Instagram's headers, navigation bars, footers, and app-download banners so the video fills 100% of the panel.
- **Muted by default** — playback always starts silent (including after reloads and SPA navigations); toggle audio from the panel's speaker button or the `M` key. The state survives hide/show cycles.
- **Keyboard driven** — global and local shortcuts (see table below); letter-key actions are suppressed while you're typing in Instagram's login form.
- **Auto-scroll engine** — advances to the next reel when the current video emits its `ended` event, with a 120-second fallback timer for stalled playback. An "Auto" badge shows on the panel while enabled.
- **Battery friendly** — when the panel closes or the app deactivates, all videos pause, audio is muted, and timers are suspended. Idle CPU with the panel closed measures ~0%.
- **Agent app** — `LSUIElement` is enabled, so ReelsBar runs entirely from the menu bar with no Dock icon or App Switcher entry.

## Keyboard shortcuts

| Shortcut | Scope | Action |
| --- | --- | --- |
| ⌘⇧R | Global (any app) | Show / hide the panel |
| ↑ / ↓ | Panel | Previous / next reel |
| Space | Panel | Play / pause current video |
| M | Panel | Mute / unmute |
| A | Panel | Toggle auto-scroll |
| L | Panel | Like the active reel |

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
| `ReelsBar/ReelsBarApp.swift` | App entry: `MenuBarExtra` scene, wires observers/hotkeys into `AppModel`. |
| `ReelsBar/AppModel.swift` | Central `@Observable` state: mute, auto-scroll, panel lifecycle, keyboard actions, Carbon hotkey toggle, fallback timer. |
| `ReelsBar/ReelsBarPanel.swift` | The 375×667 panel: web view plus overlay controls (mute button, auto-scroll badge). |
| `ReelsBar/ReelsWebView.swift` | `NSViewRepresentable` WKWebView: iPhone UA, Reels URL, navigation delegate, script-message handler. |
| `ReelsBar/ReelsUserScript.swift` | Injected JavaScript/CSS: DOM cleanup, `window.__reelsbar` bridge (mute, scroll, play, like, ended events). |
| `ReelsBar/HotkeyManager.swift` | Carbon `RegisterEventHotKey` for the system-wide ⌘⇧R toggle. |

The native ↔ web boundary is the `window.__reelsbar` bridge: native code calls its methods via `evaluateJavaScript`, and the page reports video `ended` events back through a `webkit.messageHandlers.reelsbar` script message.

## Security & privacy

- **App Sandbox** is enabled with only `com.apple.security.network.client` (outgoing connections); no file, camera, or microphone access.
- The app ships no analytics and stores nothing outside the sandboxed web view data store (Instagram cookies/session).
- Developed with ad-hoc signing ("Sign to Run Locally"); re-sign with a Developer ID certificate for distribution.

## Known limitations

- Instagram's DOM is undocumented and changes frequently. The CSS selectors, the like-button lookup, and the feed-scroller heuristics in `ReelsUserScript.swift` are best-effort and may need retuning if Instagram updates its web client.
- The like action (`L`) simulates a click on the visible reel's Like button; it can't bypass Instagram's login walls or bot detection.
- WKWebView blocks unmuted autoplay, which is why playback always starts silent — this doubles as the mute-by-default policy.
