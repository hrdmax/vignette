import AppKit
import ApplicationServices

/// Accessibility is the one permission Vignette cannot work without: it is how we
/// learn the focused window's frame. macOS grants it per code signature, so a
/// rebuild with a different signing identity silently revokes it.
@MainActor
enum Permissions {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system prompt. Only shows once per signature; afterwards the
    /// user has to toggle it manually, so pair this with `openAccessibilitySettings`.
    @discardableResult
    static func requestAccessibility() -> Bool {
        // Swift 6 won't let us touch `kAXTrustedCheckOptionPrompt` (a mutable C
        // global). Its value is this documented, stable string.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
