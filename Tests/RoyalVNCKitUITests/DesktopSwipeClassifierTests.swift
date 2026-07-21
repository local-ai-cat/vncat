import CoreGraphics
import Testing

@testable import RoyalVNCKitUI

struct DesktopSwipeClassifierTests {
    @Test func classifiesThreeFingerSwipeUpAsMissionControl() {
        let action = DesktopSwipeClassifier.action(
            translation: CGPoint(x: 8, y: -90),
            velocity: CGPoint(x: 20, y: -500),
            touchCount: 3,
            allTouchesDownBeforeMovement: true
        )

        #expect(action == .missionControl)
    }

    @Test func classifiesFourFingerSwipeDownAsAppExpose() {
        let action = DesktopSwipeClassifier.action(
            translation: CGPoint(x: -12, y: 100),
            velocity: CGPoint(x: -30, y: 450),
            touchCount: 4,
            allTouchesDownBeforeMovement: true
        )

        #expect(action == .appExpose)
    }

    @Test func rejectsAmbiguousOrConflictingSwipes() {
        #expect(classify(translation: CGPoint(x: 0, y: 60)) == nil)
        #expect(classify(velocity: CGPoint(x: 0, y: 250)) == nil)
        #expect(classify(translation: CGPoint(x: 80, y: 90)) == nil)
        #expect(classify(touchCount: 2) == nil)
        #expect(classify(allTouchesDownBeforeMovement: false) == nil)
    }

    private func classify(
        translation: CGPoint = CGPoint(x: 0, y: 90),
        velocity: CGPoint = CGPoint(x: 0, y: 500),
        touchCount: Int = 3,
        allTouchesDownBeforeMovement: Bool = true
    ) -> DesktopSwipeAction? {
        DesktopSwipeClassifier.action(
            translation: translation,
            velocity: velocity,
            touchCount: touchCount,
            allTouchesDownBeforeMovement: allTouchesDownBeforeMovement
        )
    }
}
