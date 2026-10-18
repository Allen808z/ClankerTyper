import CoreGraphics
import Testing
@testable import ClankerTyper

@Suite("Selection toolbar trigger")
struct SelectionToolbarTests {
    @Test func convertsAccessibilityRectToScreenCoordinates() {
        // A selection 100 pt from the top of a 900 pt tall main screen, 20 pt high.
        let rect = FocusTracker.appKitRect(fromAccessibility: CGRect(x: 50, y: 100, width: 200, height: 20),
                                           primaryScreenHeight: 900)
        #expect(rect == CGRect(x: 50, y: 780, width: 200, height: 20))
    }

    @Test func offersOnlyRealText() {
        #expect(SelectionToolbar.shouldOffer("teh cat sat"))
        #expect(!SelectionToolbar.shouldOffer("  "))
        #expect(!SelectionToolbar.shouldOffer("a"))
        #expect(!SelectionToolbar.shouldOffer("12345"))
        #expect(!SelectionToolbar.shouldOffer(String(repeating: "word ", count: 2000)))
    }
}
