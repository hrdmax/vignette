import AppKit
import Carbon.HIToolbox

/// Registers one global shortcut through Carbon's `RegisterEventHotKey`.
///
/// Carbon, and not `NSEvent.addGlobalMonitorForEvents`, on purpose: installing an
/// NSEvent global monitor stops MenuBarExtra's status item from opening its menu
/// at all (found by bisecting, see FocusTracker). Carbon's hotkey API is a
/// separate mechanism, needs no extra permission, and doesn't interfere.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    var isRegistered: Bool { hotKeyRef != nil }

    /// Registers `hotkey`, replacing any previous one. `nil` just unregisters.
    /// Returns false if the system refused it, which usually means something else
    /// already owns that combination.
    @discardableResult
    func update(to hotkey: Hotkey?) -> Bool {
        unregister()
        guard let hotkey else { return true }

        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5647_4E54), id: 1)  // 'VGNT'
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &spec,
            nil,
            &handlerRef
        )
    }
}

/// C callback, so it captures nothing. Carbon delivers on the main thread.
private func hotkeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    MainActor.assumeIsolated {
        HotkeyManager.shared.onTrigger?()
    }
    return noErr
}
