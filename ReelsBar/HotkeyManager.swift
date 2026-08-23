import AppKit
import Carbon.HIToolbox

/// System-wide ⌘⇧R toggle for the panel, registered via Carbon so it works
/// from any application without accessibility permissions.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onToggle: () -> Void

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    deinit {
        unregister()
    }

    func register() {
        guard hotKeyRef == nil else { return }

        var hotKeyID = EventHotKeyID(signature: OSType(0x52424152), id: 1) // 'RBAR'
        let modifiers = UInt32(cmdKey | shiftKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_R), modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            return manager.handleHotKeyEvent(event)
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        var hkID = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &hkID)
        guard hkID.id == 1 else { return noErr }
        DispatchQueue.main.async { [onToggle] in onToggle() }
        return noErr
    }

    func unregister() {
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
