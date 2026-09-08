import AppKit
import ApplicationServices

struct FocusedWindow: Equatable {
    let pid: pid_t
    let appName: String
    /// Global coordinates with a **top-left** origin, the way AX reports them.
    /// Convert with `FocusedWindow.flipped(_:)` before handing to AppKit.
    let frame: CGRect

    /// AppKit windows use a bottom-left origin anchored to the primary display,
    /// so flipping needs the *primary* screen's height, not the one we're on.
    static func flipped(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(
            x: rect.minX,
            y: primary.frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

@MainActor
final class FocusTracker {
    private(set) var current: FocusedWindow? {
        didSet { if current != oldValue { onChange?(current) } }
    }

    var onChange: ((FocusedWindow?) -> Void)?

    private var activationObserver: NSObjectProtocol?
    private var pollTimer: Timer?

    func start() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }

        // Placeholder until AXObserver lands: a poll catches moves/resizes that
        // app-activation notifications never fire for. Replace, don't keep.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }

        refresh()
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        current = Self.readFocusedWindow()
    }

    private static func readFocusedWindow() -> FocusedWindow? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = copyElement(axApp, kAXFocusedWindowAttribute),
              let origin = copyPoint(window, kAXPositionAttribute),
              let size = copySize(window, kAXSizeAttribute)
        else { return nil }

        return FocusedWindow(
            pid: app.processIdentifier,
            appName: app.localizedName ?? "Unknown",
            frame: CGRect(origin: origin, size: size)
        )
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        return (ref as! AXUIElement)
    }

    private static func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        return (ref as! AXValue)
    }

    private static func copyPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAXValue(element, attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAXValue(element, attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }
}
