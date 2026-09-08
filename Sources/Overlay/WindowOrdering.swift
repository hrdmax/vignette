import AppKit

/// Places a window directly beneath another application's window.
///
/// This is the operation the whole design wants and AppKit will not give us:
/// `NSWindow.orderWindow(_:relativeTo:)` is same-application only, and window
/// levels are coarse buckets you cannot insert yourself into. The WindowServer
/// keeps exactly this ordering internally; SkyLight is the interface to it.
///
/// **These are private symbols.** They are resolved with `dlsym` rather than
/// linked, so a macOS release that removes or renames them degrades to
/// `isAvailable == false` instead of failing to launch. Callers must have a
/// fallback — here, the hole-punching mask.
@MainActor
enum WindowOrdering {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias OrderWindowFn = @convention(c) (Int32, UInt32, Int32, UInt32) -> Int32

    /// Ordering modes SkyLight understands.
    private enum Mode: Int32 {
        case below = -1
        case out = 0
        case above = 1
    }

    private static let library: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }()

    /// SkyLight is the modern home; CoreGraphics carried the CGS-prefixed
    /// equivalents historically. Try both before giving up.
    private static func symbol(_ names: [String]) -> UnsafeMutableRawPointer? {
        for name in names {
            if let library, let found = dlsym(library, name) { return found }
            if let found = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { return found }
        }
        return nil
    }

    private static let connectionID: Int32? = {
        guard let pointer = symbol(["SLSMainConnectionID", "CGSMainConnectionID"]) else {
            return nil
        }
        return unsafeBitCast(pointer, to: MainConnectionIDFn.self)()
    }()

    private static let orderWindow: OrderWindowFn? = {
        guard let pointer = symbol(["SLSOrderWindow", "CGSOrderWindow"]) else { return nil }
        return unsafeBitCast(pointer, to: OrderWindowFn.self)
    }()

    static var isAvailable: Bool {
        connectionID != nil && orderWindow != nil
    }

    /// Orders `window` directly below `other`. Because the focused window is
    /// already topmost, "just below it" also means "above everything else".
    @discardableResult
    static func place(_ window: CGWindowID, below other: CGWindowID) -> Bool {
        guard let connectionID, let orderWindow else { return false }
        return orderWindow(connectionID, window, Mode.below.rawValue, other) == 0
    }

    /// Prints the real front-to-back order of on-screen windows, marking ours.
    /// `CGWindowListCopyWindowInfo` returns them in z-order, so this is the
    /// ground truth for whether an ordering call actually took effect.
    static func dumpOrder(ours: Set<CGWindowID>, limit: Int = 8) {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return }

        var lines: [String] = []
        for entry in list {
            guard let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
            lines.append("\(ours.contains(number) ? "OVERLAY" : owner)")
            if lines.count >= limit { break }
        }
        print("[vignette] z-order front→back: \(lines.joined(separator: " > "))")
    }

    /// The WindowServer's id for a window AX told us about.
    ///
    /// Matched on owning process and exact bounds rather than a private AX call:
    /// `_AXUIElementGetWindow` would do it directly, but the two sources were
    /// verified to agree to the point, so this keeps one fewer private symbol.
    static func windowID(pid: pid_t, frame: CGRect) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        // Every numeric field is bridged through NSNumber rather than cast
        // directly: `as? CGWindowID` is `as? UInt32`, which fails against an
        // NSNumber even when the value is perfectly valid. That silently killed
        // every lookup here, so the ordering call was never even reached.
        for entry in list {
            guard let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == pid,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            // A point of tolerance, rather than exact equality: the two sources
            // agree in practice but nothing guarantees identical rounding.
            if abs(bounds.minX - frame.minX) <= 1,
               abs(bounds.minY - frame.minY) <= 1,
               abs(bounds.width - frame.width) <= 1,
               abs(bounds.height - frame.height) <= 1 {
                return number
            }
        }
        return nil
    }
}
