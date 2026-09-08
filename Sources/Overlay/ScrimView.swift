import AppKit
import QuartzCore

/// Dims its entire bounds except for `hole`, which is punched clean through.
///
/// Step 3 replaces the flat dim fill with an `NSVisualEffectView` for a real blur.
/// The even-odd mask below is what does the punching, and carries over unchanged —
/// which is why the mask lives here rather than in a `draw(_:)` override.
final class ScrimView: NSView {
    /// 0 = invisible, 1 = fully black.
    var dimming: CGFloat = 0.55 {
        didSet { updateOpacity(animated: false) }
    }

    /// Temporarily hides the scrim without disturbing `dimming`, used while a
    /// window is being dragged and its reported position is stale.
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            // Hide instantly so the scrim never trails the window; fade back in,
            // because an abrupt reappearance is jarring.
            updateOpacity(animated: !isSuspended)
        }
    }

    var cornerRadius: CGFloat = 10

    /// The unblurred cut-out, in this view's own bottom-left-origin coordinates.
    /// `nil` dims the whole screen.
    var hole: CGRect? {
        didSet { if hole != oldValue { applyMask() } }
    }

    private let maskLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        maskLayer.fillRule = .evenOdd
        layer?.mask = maskLayer
        updateOpacity(animated: false)
        applyMask()
    }

    private func updateOpacity(animated: Bool) {
        guard let layer else { return }
        let target = isSuspended ? 0 : Float(dimming)

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.12) }
        layer.opacity = target
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ScrimView is created in code only") }

    override func layout() {
        super.layout()
        applyMask()
    }

    private func applyMask() {
        let path = CGMutablePath()
        path.addRect(bounds)

        if let hole {
            let clipped = hole.intersection(bounds)
            if !clipped.isNull, !clipped.isEmpty {
                path.addPath(
                    CGPath(
                        roundedRect: clipped,
                        cornerWidth: cornerRadius,
                        cornerHeight: cornerRadius,
                        transform: nil
                    )
                )
            }
        }

        // Implicit animation would smear the hole a frame behind a dragged window.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = bounds
        maskLayer.path = path
        CATransaction.commit()
    }
}
