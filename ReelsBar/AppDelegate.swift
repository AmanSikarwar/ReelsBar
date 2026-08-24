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
            button.action = #selector(togglePopover)
            button.toolTip = "ReelsBar (⌘⇧R)"
        }
        self.statusItem = statusItem

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 375, height: 812)
        popover.contentViewController = NSHostingController(
            rootView: ReelsBarPanel().environment(appModel)
        )
        popover.delegate = self

        appModel.startInputMonitoring()
        hotkeyManager = HotkeyManager { [weak self] in
            self?.togglePopover()
        }
        hotkeyManager?.register()
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
