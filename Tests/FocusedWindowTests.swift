import Testing
import AppKit
@testable import Vignette

@MainActor
struct FocusedWindowTests {
    /// AX reports top-left origin; AppKit wants bottom-left off the primary display.
    @Test func flipsAgainstPrimaryScreenHeight() throws {
        let primaryHeight = try #require(NSScreen.screens.first).frame.height
        let axRect = CGRect(x: 100, y: 200, width: 400, height: 300)

        let flipped = FocusedWindow.flipped(axRect)

        #expect(flipped.minX == 100)
        #expect(flipped.minY == primaryHeight - 500)
        #expect(flipped.size == axRect.size)
    }
}
