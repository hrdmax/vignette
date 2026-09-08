import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, stored in the form Carbon wants it.
///
/// `display` is captured at record time rather than derived from `keyCode` later:
/// mapping a virtual key code back to a printed character needs the user's current
/// keyboard layout, and gets it wrong on non-US layouts.
struct Hotkey: Codable, Equatable {
    let keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, …), not `NSEvent.ModifierFlags`.
    let modifiers: UInt32
    let display: String

    static func from(event: NSEvent) -> Hotkey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }

        let key = keyName(for: event)
        guard !key.isEmpty else { return nil }

        // Function keys work alone; anything else needs a modifier, or the
        // shortcut would swallow ordinary typing everywhere.
        let isFunctionKey = flags.contains(.function) || key.hasPrefix("F")
        guard carbon != 0 || isFunctionKey else { return nil }

        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }

        return Hotkey(
            keyCode: UInt32(event.keyCode),
            modifiers: carbon,
            display: symbols + key
        )
    }

    private static func keyName(for event: NSEvent) -> String {
        if let named = specialKeys[Int(event.keyCode)] { return named }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return ""
        }
        return characters.uppercased()
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Escape: "⎋",
        kVK_Delete: "⌫",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
    ]
}
