import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSMenuDelegate {
    private let appModel = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var hotkeyManager: HotkeyManager?
    private var statusMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "play.rectangle.on.rectangle.fill",
                accessibilityDescription: "ReelsBar"
            )
            button.target = self
            button.action = #selector(statusButtonClicked)
            // Left-click toggles; right-click (or Ctrl-click) opens the menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "ReelsBar (⌘⇧R)"
        }
        self.statusItem = statusItem

        popover.behavior = .transient
        popover.contentSize = AppModel.contentSize(forReelMode: appModel.isReelMode)
        appModel.reelModeDidChange = { [weak self] isReelMode in
            self?.popover.contentSize = AppModel.contentSize(forReelMode: isReelMode)
        }
        popover.contentViewController = NSHostingController(
            rootView: ReelsBarPanel().environment(appModel)
        )
        popover.delegate = self

        appModel.startInputMonitoring()
        hotkeyManager = HotkeyManager { [weak self] in
            self?.togglePopover()
        }
        if hotkeyManager?.register() == false {
            showHotkeyFailureAlert()
        }
    }

    @objc private func statusButtonClicked() {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp
            || event.modifierFlags.contains(.control) {
            showStatusMenu()
        } else {
            togglePopover()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let toggleTitle = popover.isShown ? "Hide ReelsBar" : "Show ReelsBar"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(togglePopover), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit ReelsBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        // Retain until menuDidClose: clearing synchronously after
        // performClick races menu presentation on some macOS versions.
        statusMenu = menu
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so left-click toggles again instead of reopening the menu.
        if statusMenu === menu {
            if statusItem?.menu === menu {
                statusItem?.menu = nil
            }
            statusMenu = nil
        }
    }

    private func showHotkeyFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "ReelsBar hotkey unavailable"
        alert.informativeText = "⌘⇧R could not be registered (it may be taken by another app). Use the menu bar icon or right-click menu instead."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        // Run async: the agent app may not be active yet at launch.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        appModel.handlePanelActivated()
        appModel.webView?.window?.makeFirstResponder(appModel.webView)
    }

    func popoverDidClose(_ notification: Notification) {
        appModel.handlePanelDeactivated()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // The transient popover may still be shown while the app loses key
        // status; pause media/timers immediately instead of waiting for
        // popoverDidClose. Guarded: no-op when already inactive.
        appModel.handlePanelDeactivated()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Resume only if the panel is still visible; a closed popover must
        // stay suspended for the battery-friendly idle guarantee.
        if popover.isShown {
            appModel.handlePanelActivated()
        }
    }
}
