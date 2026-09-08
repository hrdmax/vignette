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

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)

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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
