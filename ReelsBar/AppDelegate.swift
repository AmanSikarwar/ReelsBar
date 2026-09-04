import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let appModel = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var hotkeyManager: HotkeyManager?

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
        popover.contentSize = AppModel.reelSize
        appModel.reelModeDidChange = { [weak self] isReelMode in
            self?.popover.contentSize = isReelMode ? AppModel.reelSize : AppModel.panelSize
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
        let toggleTitle = popover.isShown ? "Hide ReelsBar" : "Show ReelsBar"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(togglePopover), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit ReelsBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Detach so left-click toggles again instead of reopening the menu.
        statusItem?.menu = nil
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
}
