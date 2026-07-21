import CoreGraphics
import Testing

@testable import RoyalVNCKitUI

struct KeyboardToolbarGeometryTests {
    private let viewBounds = CGRect(x: 0, y: 0, width: 390, height: 844)

    @Test func returnsTrueBottomIntersectionHeight() {
        let keyboardFrame = CGRect(x: 0, y: 544, width: 390, height: 300)

        #expect(KeyboardToolbarGeometry.bottomOverlapHeight(
            viewBounds: viewBounds,
            keyboardFrame: keyboardFrame
        ) == 300)
    }

    @Test func ignoresFloatingKeyboard() {
        let keyboardFrame = CGRect(x: 80, y: 400, width: 250, height: 180)

        #expect(KeyboardToolbarGeometry.bottomOverlapHeight(
            viewBounds: viewBounds,
            keyboardFrame: keyboardFrame
        ) == 0)
    }

    @Test func clipsKeyboardFrameToViewBounds() {
        let keyboardFrame = CGRect(x: 0, y: 700, width: 390, height: 300)

        #expect(KeyboardToolbarGeometry.bottomOverlapHeight(
            viewBounds: viewBounds,
            keyboardFrame: keyboardFrame
        ) == 144)
    }
}
