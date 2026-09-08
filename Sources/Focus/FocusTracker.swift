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

/// Notifications watched on the focused *application* element.
private let appNotifications = [
    kAXFocusedWindowChangedNotification,
    kAXMainWindowChangedNotification,
    kAXApplicationHiddenNotification,
    kAXApplicationShownNotification,
]

/// Notifications watched on the focused *window* element. These are the ones that
/// make dragging feel live — AX pushes them continuously during a drag.
private let windowNotifications = [
    kAXWindowMovedNotification,
    kAXWindowResizedNotification,
    kAXUIElementDestroyedNotification,
]

/// C callback, so it must capture nothing — `self` arrives via the refcon pointer.
/// AX delivers on the run loop we registered with, i.e. the main one.
private func focusObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { tracker.handle(notification: name) }
}

@MainActor
final class FocusTracker {
    private(set) var current: FocusedWindow? {
        didSet { if current != oldValue { onChange?(current) } }
    }

    var onChange: ((FocusedWindow?) -> Void)?

    private var activationObserver: NSObjectProtocol?
    private var safetyNetTimer: Timer?

    private var axObserver: AXObserver?
    private var observedPID: pid_t?
    private var observedWindow: AXUIElement?

    private var motionTimer: Timer?
    private var lastMotionAt: Date?

    private struct Snapshot {
        let window: FocusedWindow
        let element: AXUIElement
    }

    func start() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }

        // Not every app is a good AX citizen — some never emit move/resize. A slow
        // poll keeps those from getting stuck, without the cost of the old 250ms one.
        safetyNetTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.refresh() }
        }

        refresh()
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        safetyNetTimer?.invalidate()
        safetyNetTimer = nil
        endMotionTracking()
        detachObserver()
    }

    func handle(notification: String) {
        // macOS coalesces move notifications during a drag (the WindowServer owns
        // the drag; the app reports position only sporadically). Resize streams
        // fine. So on the first move we poll hard until the window settles.
        if notification == kAXWindowMovedNotification {
            beginMotionTracking()
        }
        refresh()
    }

    func refresh() {
        let snapshot = Self.readFocused()
        current = snapshot?.window
        retarget(snapshot)
    }

    // MARK: - Motion tracking

    private func beginMotionTracking() {
        lastMotionAt = Date()
        guard motionTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.refresh()
                if Date().timeIntervalSince(self.lastMotionAt ?? .distantPast) > 0.2 {
                    self.endMotionTracking()
                }
            }
        }
        // .common so it keeps firing while the run loop is in event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func endMotionTracking() {
        motionTimer?.invalidate()
        motionTimer = nil
        lastMotionAt = nil
    }

    // MARK: - Observer wiring

    private func retarget(_ snapshot: Snapshot?) {
        guard let snapshot else {
            detachObserver()
            return
        }

        if observedPID != snapshot.window.pid {
            attachObserver(pid: snapshot.window.pid)
        }

        if let observedWindow, CFEqual(observedWindow, snapshot.element) { return }
        observeWindow(snapshot.element)
    }

    private func attachObserver(pid: pid_t) {
        detachObserver()

        var observer: AXObserver?
        guard AXObserverCreate(pid, focusObserverCallback, &observer) == .success,
              let observer
        else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        for name in appNotifications {
            AXObserverAddNotification(observer, appElement, name as CFString, refcon)
        }

        // .commonModes, not .defaultMode: we must keep receiving callbacks while
        // the run loop is in event-tracking mode during a drag.
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )

        axObserver = observer
        observedPID = pid
    }

    private func observeWindow(_ element: AXUIElement) {
        guard let axObserver else { return }

        if let observedWindow {
            for name in windowNotifications {
                AXObserverRemoveNotification(axObserver, observedWindow, name as CFString)
            }
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in windowNotifications {
            AXObserverAddNotification(axObserver, element, name as CFString, refcon)
        }

        observedWindow = element
    }

    private func detachObserver() {
        if let axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(axObserver),
                .commonModes
            )
        }
        axObserver = nil
        observedPID = nil
        observedWindow = nil
    }

    // MARK: - Reading AX

    private static func readFocused() -> Snapshot? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = copyElement(axApp, kAXFocusedWindowAttribute),
              let origin = copyPoint(window, kAXPositionAttribute),
              let size = copySize(window, kAXSizeAttribute)
        else { return nil }

        return Snapshot(
            window: FocusedWindow(
                pid: app.processIdentifier,
                appName: app.localizedName ?? "Unknown",
                frame: CGRect(origin: origin, size: size)
            ),
            element: window
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
