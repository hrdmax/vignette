import AppKit

/// Owns one `OverlayWindow` per screen and keeps their holes aligned with the
/// focused window.
///
/// Coordinate chain, which is where the bugs live:
///   AX frame (global, top-left origin)
///     → `FocusedWindow.flipped` (global, bottom-left origin, AppKit convention)
///     → minus the overlay window's origin (that window's local coordinates)
@MainActor
final class OverlayController {
    private(set) var isEnabled = false

    /// Strength of the black tint over the blur. 0 = blur only.
    var dimming: CGFloat = 0.25 {
        didSet {
            for window in windows { window.scrim?.dimming = dimming }
        }
    }

    /// Switching the feature on or off is a deliberate act, so it gets a fade the
    /// user can actually see.
    private let toggleFade: TimeInterval = 0.20
    /// Leaving on a drag is quick, so the scrim doesn't visibly trail the window.
    private let dragFadeOut: TimeInterval = 0.08
    /// Coming back is slower; an abrupt reappearance reads as a flash.
    private let dragFadeIn: TimeInterval = 0.16
    /// Focus moving somewhere we can't read.
    private let focusFade: TimeInterval = 0.12

    private var windows: [OverlayWindow] = []
    private var lastFocused: FocusedWindow?
    private var screenObserver: NSObjectProtocol?
    private var isSuspended = false
    private var teardownTimer: Timer?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.isEnabled else { return }
                self.rebuildWindows()
                self.applyHoles(self.lastFocused)
                self.updateVisibility(duration: 0)
            }
        }
    }

    // No deinit: this controller lives as long as the app does, and a nonisolated
    // deinit can't touch main-actor state anyway.

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled

        if enabled {
            teardownTimer?.invalidate()
            teardownTimer = nil
            if windows.isEmpty { rebuildWindows() }
            applyHoles(lastFocused)
            updateVisibility(duration: toggleFade)
        } else {
            updateVisibility(duration: toggleFade)
            // Let the fade finish before the windows go away, or there is nothing
            // left on screen to animate.
            scheduleTeardown(after: toggleFade)
        }
    }

    func update(focused: FocusedWindow?) {
        let hadFocus = lastFocused != nil
        lastFocused = focused
        guard isEnabled else { return }

        applyHoles(focused)
        if hadFocus != (focused != nil) {
            updateVisibility(duration: focusFade)
        }
    }

    /// Stands the scrim down while the focused window is being dragged. The AX
    /// position is stale mid-drag, so a visible scrim would simply lag behind.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        updateVisibility(duration: suspended ? dragFadeOut : dragFadeIn)
    }

    // MARK: - Internals

    /// With no identifiable focused window we hide the scrim entirely rather than
    /// blurring everything. "The screen went dark" is a much worse failure than
    /// "the effect switched off for a moment".
    private var shouldBeVisible: Bool {
        isEnabled && !isSuspended && lastFocused != nil
    }

    private func updateVisibility(duration: TimeInterval) {
        let visible = shouldBeVisible

        for window in windows {
            if visible {
                window.orderFront(nil)
                window.fade(to: 1, duration: duration)
            } else {
                window.fade(to: 0, duration: duration) {
                    MainActor.assumeIsolated { [weak self, weak window] in
                        // Re-check: the state may have flipped back mid-fade.
                        guard let self, let window, !self.shouldBeVisible else { return }
                        window.orderOut(nil)
                    }
                }
            }
        }
    }

    /// EXPERIMENT: no hole at all. The focused window is lifted above the blur
    /// instead of being cut out of it, so there is no geometry to track — no
    /// coordinate flipping, no corner radius, no drag lag, no multi-display maths.
    private func applyHoles(_ focused: FocusedWindow?) {
        for window in windows { window.scrim?.hole = nil }
    }

    /// Puts the blur above other applications' windows without activating us.
    func bringToFront() {
        // No isVisible guard: at enable time the overlay is still fading in and
        // reports invisible, which silently skipped the initial ordering.
        for window in windows {
            window.orderFrontRegardless()
        }
    }

    private func scheduleTeardown(after delay: TimeInterval) {
        teardownTimer?.invalidate()
        let timer = Timer(timeInterval: delay + 0.05, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.teardownTimer = nil
                guard !self.isEnabled else { return }
                self.teardownWindows()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        teardownTimer = timer
    }

    private func rebuildWindows() {
        teardownWindows()
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(screen: screen)
            window.scrim?.dimming = dimming
            return window
        }
    }

    private func teardownWindows() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }
}
