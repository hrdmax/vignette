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

    /// 0 = invisible, 1 = fully black.
    var dimming: CGFloat = 0.55 {
        didSet {
            for window in windows { window.scrim?.dimming = dimming }
        }
    }

    private var windows: [OverlayWindow] = []
    private var lastFocused: FocusedWindow?
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.isEnabled else { return }
                self.rebuildWindows()
                self.apply(self.lastFocused)
            }
        }
    }

    // No deinit: this controller lives as long as the app does, and a nonisolated
    // deinit can't touch main-actor state anyway.

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled

        if enabled {
            rebuildWindows()
            apply(lastFocused)
        } else {
            teardownWindows()
        }
    }

    func update(focused: FocusedWindow?) {
        lastFocused = focused
        guard isEnabled else { return }
        apply(focused)
    }

    // MARK: - Internals

    private func apply(_ focused: FocusedWindow?) {
        // With no identifiable focused window we hide the scrim entirely rather
        // than dimming everything. "The screen went dark" is a much worse failure
        // than "the effect switched off for a moment".
        guard let focused else {
            for window in windows { window.orderOut(nil) }
            return
        }

        let globalHole = FocusedWindow.flipped(focused.frame)

        for window in windows {
            let origin = window.frame.origin
            window.scrim?.hole = CGRect(
                x: globalHole.minX - origin.x,
                y: globalHole.minY - origin.y,
                width: globalHole.width,
                height: globalHole.height
            )
            window.orderFront(nil)
        }
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
