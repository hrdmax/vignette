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

    /// Fires `true` on the first pixel of a drag, `false` shortly after mouse-up.
    var onMotionChange: ((Bool) -> Void)?

    /// Grace period after mouse-up before the scrim returns, so it lands on the
    /// window's final position rather than its second-to-last one.
    var dragReleaseSettleDelay: TimeInterval = 0.05

    /// How close to a window edge a press has to be to read as a resize grab.
    /// macOS itself uses a band of roughly this width.
    private let resizeEdgeSlop: CGFloat = 8

    /// Standard macOS title bar. Kept conservative on purpose — see `beginDrag`.
    private let titleBarHeight: CGFloat = 28

    private var mouseTimer: Timer?
    private var releaseTimer: Timer?
    private var isMoving = false
    private var wasButtonDown = false
    private var pressOrigin: NSPoint?
    private var isDragging = false
    private var sawResizeThisDrag = false

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
            MainActor.assumeIsolated { [weak self] in
                self?.refresh()
            }
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
        stopWatchingMouse()
        releaseTimer?.invalidate()
        releaseTimer = nil
        detachObserver()
    }

    func handle(notification: String) {
        if isDragging {
            switch notification {
            case kAXWindowResizedNotification:
                // Live geometry — so this was a resize, not a move. Latch it: a
                // corner resize also emits move notifications, and those must not
                // flip us back into suspending.
                sawResizeThisDrag = true
                resume()
            case kAXWindowMovedNotification:
                if !sawResizeThisDrag { suspend() }
            default:
                break
            }
        }
        refresh()
    }

    func refresh() {
        let snapshot = Self.readFocused()
        current = snapshot?.window
        retarget(snapshot)
    }

    // MARK: - Drag tracking

    // macOS hands live window drags to the WindowServer, and the AX position
    // attribute stays stale for the duration — polling it harder doesn't help
    // (measured). So we don't ask AX whether a drag is happening; we watch the
    // mouse directly. That fires on the first pixel of movement rather than
    // whenever the app gets round to reporting itself, and gives us a real
    // mouse-up instead of inferring the end from a timeout.
    //
    // Resize is unaffected: those notifications stream with live geometry, and
    // nothing here touches that path.

    /// Watching the mouse is opt-in because it costs a 60Hz timer: the caller
    /// turns it on only while the overlay is actually up.
    func setDragWatchingEnabled(_ enabled: Bool) {
        if enabled {
            startWatchingMouse()
        } else {
            stopWatchingMouse()
            isDragging = false
            sawResizeThisDrag = false
            resume()
        }
    }

    // We poll the mouse rather than installing an NSEvent global monitor. A
    // monitor stops MenuBarExtra's status item from opening its menu at all
    // (verified by bisecting against main), and there is no way to have both.
    // Reading the button state directly needs no monitor and no permission.

    private func startWatchingMouse() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.pollMouse() }
        }
        // .common so it keeps firing while the run loop is in event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopWatchingMouse() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        wasButtonDown = false
        pressOrigin = nil
    }

    private func pollMouse() {
        let isDown = NSEvent.pressedMouseButtons & 1 != 0
        let location = NSEvent.mouseLocation
        defer { wasButtonDown = isDown }

        if isDown, !wasButtonDown {
            pressOrigin = location
            return
        }

        if isDown, !isDragging, let origin = pressOrigin {
            // A few points of slop, so a plain click never counts as a drag.
            if hypot(location.x - origin.x, location.y - origin.y) > 2 {
                beginDrag()
            }
            return
        }

        if !isDown, wasButtonDown {
            pressOrigin = nil
            endDrag()
        }
    }

    private func beginDrag() {
        guard !isDragging else { return }
        isDragging = true
        sawResizeThisDrag = false

        // A press on the window's edge is a resize grab. AX streams live geometry
        // for resizes, so the scrim can stay up and track it.
        if pressIsOnWindowEdge() {
            sawResizeThisDrag = true
            return
        }

        // Otherwise: a drag is not proof the window is moving. Selecting text,
        // dragging a scrollbar or a file all look identical to the mouse. Only AX
        // can say a window actually moved, so we wait for it — with one exception.
        //
        // The exception is a press on the title bar, which is a window drag
        // essentially every time. Suspending there immediately keeps the common
        // case instant, since the first move notification arrives too late to
        // rely on. The band is deliberately narrow: guessing wrong here costs a
        // visible delay, while guessing nothing at all just defers to AX.
        if pressIsOnTitleBar() {
            suspend()
        }
    }

    private func suspend() {
        guard !isMoving else { return }
        isMoving = true
        onMotionChange?(true)
    }

    /// Bring the dim back mid-drag, once we know this is a resize after all.
    private func resume() {
        guard isMoving else { return }
        isMoving = false
        onMotionChange?(false)
    }

    /// Top strip of the focused window, excluding the resize edges.
    private func pressIsOnTitleBar() -> Bool {
        guard let pressOrigin, let current else { return false }
        let frame = FocusedWindow.flipped(current.frame)
        guard frame.height > titleBarHeight else { return false }

        // AppKit's y grows upward, so the title bar is the top of the rect.
        let band = CGRect(
            x: frame.minX + resizeEdgeSlop,
            y: frame.maxY - titleBarHeight,
            width: max(0, frame.width - resizeEdgeSlop * 2),
            height: titleBarHeight - resizeEdgeSlop
        )
        return band.contains(pressOrigin)
    }

    private func pressIsOnWindowEdge() -> Bool {
        guard let pressOrigin, let current else { return false }
        let frame = FocusedWindow.flipped(current.frame)
        let outer = frame.insetBy(dx: -resizeEdgeSlop, dy: -resizeEdgeSlop)
        let inner = frame.insetBy(dx: resizeEdgeSlop, dy: resizeEdgeSlop)
        return outer.contains(pressOrigin) && !inner.contains(pressOrigin)
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        sawResizeThisDrag = false

        guard isMoving else {
            refresh()
            return
        }
        releaseTimer?.invalidate()

        // Give the app one beat to publish its final position, so the scrim never
        // fades back in around a stale rect. Imperceptible on release.
        refresh()
        let timer = Timer(timeInterval: dragReleaseSettleDelay, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.releaseTimer = nil
                guard self.isMoving else { return }
                self.isMoving = false
                self.refresh()
                self.onMotionChange?(false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
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
