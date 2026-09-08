import AppKit

/// A borderless, click-through window covering exactly one screen.
///
/// Deliberately sits *below* the menu bar level: the menu bar is where Vignette's
/// only UI lives, so it has to stay visible and clickable even while the scrim is
/// up. Otherwise a bad hole position would leave no way to switch this off.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false

        // Starts invisible: every appearance is a fade in, never a hard cut.
        alphaValue = 0

        // Just under the Dock, which also puts us under the menu bar.
        //
        // Both then draw over the blur and are never dimmed — the Dock matters
        // because it is revealed on hover over whatever is on screen, and dimming
        // it made it invisible unless the focused window happened to cover that
        // part of the screen. The menu bar matters because it holds this app's
        // only UI, so it has to stay reachable even if the hole is wrong.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)

        collectionBehavior = [
            .canJoinAllSpaces,
            // .transient, not .stationary: they are opposites, and .stationary
            // means "unaffected by Exposé, stay put" — which left the scrim
            // covering Mission Control. .transient pulls the window off screen
            // for the duration instead, with no detection code.
            .transient,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]

        // Keep the scrim out of the user's own screenshots and screen shares.
        sharingType = .none

        let scrim = ScrimView(frame: NSRect(origin: .zero, size: screen.frame.size))
        scrim.autoresizingMask = [.width, .height]
        contentView = scrim

        setFrame(screen.frame, display: false)
    }

    var scrim: ScrimView? { contentView as? ScrimView }

    /// Fades the whole window, blur included.
    ///
    /// Animating the window's alpha rather than a layer's opacity is deliberate:
    /// AppKit disables implicit layer animations on layer-backed views, and a
    /// behind-window blur is composited by the WindowServer, which honours window
    /// alpha but not necessarily a layer mask's opacity.
    func fade(to alpha: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        guard duration > 0 else {
            alphaValue = alpha
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
