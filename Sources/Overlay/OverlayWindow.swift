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

        // EXPERIMENT: normal level, not above the menu bar.
        //
        // The overlay is raised above other apps' windows with
        // orderFrontRegardless(), and the focused window is then lifted back over
        // it via AX. Sitting at the normal level means the Dock (level 20) and the
        // menu bar (24) are naturally above the blur and never dimmed — two to-do
        // items that the hole-punching approach had to solve separately.
        level = .normal

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
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
