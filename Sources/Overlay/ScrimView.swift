import AppKit
import QuartzCore

/// Blurs everything within its bounds except for `hole`, which is punched clean
/// through. A black tint sits over the blur so the effect can be deepened
/// without swapping materials.
final class ScrimView: NSView {
    /// Strength of the black tint layered over the blur. 0 = blur only.
    var dimming: CGFloat = 0.25 {
        didSet { tintView.layer?.opacity = Float(dimming) }
    }

    /// Matched by eye against real windows. No single value is exact: macOS rounds
    /// different window styles differently — Finder is rounder than this, TextEdit
    /// less — and there is no API exposing another app's corner radius. 16 was the
    /// best compromise across the windows tried.
    var cornerRadius: CGFloat = 16

    /// The unblurred cut-out, in this view's own bottom-left-origin coordinates.
    /// `nil` blurs the whole screen.
    var hole: CGRect? {
        didSet { if hole != oldValue { applyMask() } }
    }

    private let maskLayer = CAShapeLayer()
    private let blurView = NSVisualEffectView()
    private let tintView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        blurView.frame = bounds
        blurView.autoresizingMask = [.width, .height]
        // .behindWindow is the whole trick: it blurs whatever is rendered beneath
        // this window, which is every other app.
        blurView.blendingMode = .behindWindow
        blurView.material = .fullScreenUI
        // Our overlay window is never key. The default state would switch the blur
        // off the moment that is true, i.e. always.
        blurView.state = .active
        blurView.appearance = NSAppearance(named: .darkAqua)
        addSubview(blurView)

        tintView.frame = bounds
        tintView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(tintView)

        maskLayer.fillRule = .evenOdd
        layer?.mask = maskLayer

        tintView.layer?.opacity = Float(dimming)
        applyMask()
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
