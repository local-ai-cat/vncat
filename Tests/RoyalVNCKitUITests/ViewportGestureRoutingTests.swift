import CoreGraphics
import Testing

@testable import RoyalVNCKitUI

struct ViewportGestureRoutingTests {
    private func route(_ touches: Int, _ scale: CGFloat, _ mode: VNCTouchNavigation) -> ViewportDragAction? {
        ViewportGestureRouting.dragAction(touchCount: touches, viewportScale: scale, navigation: mode)
    }

    @Test(arguments: [CGFloat(0.5), 1.0, 2.0, 5.0])
    func twoFingerModeOneFingerAlwaysDrivesTheRemote(scale: CGFloat) {
        #expect(route(1, scale, .twoFinger) == .moveRemotePointer)
    }

    @Test func twoFingerModeTwoFingersPanWhenZoomedAndScrollOtherwise() {
        #expect(route(2, 2, .twoFinger) == .panViewport)
        #expect(route(2, 1, .twoFinger) == .scrollRemote)
        #expect(route(2, 0.5, .twoFinger) == .scrollRemote)
    }

    @Test func classicModeOneFingerPansOnlyWhenZoomed() {
        #expect(route(1, 2, .classic) == .panViewport)
        #expect(route(1, 1, .classic) == .moveRemotePointer)
        #expect(route(1, 1.005, .classic) == .moveRemotePointer)
    }

    @Test(arguments: [CGFloat(0.5), 1.0, 2.0])
    func classicModeTwoFingersAlwaysScrollTheRemote(scale: CGFloat) {
        #expect(route(2, scale, .classic) == .scrollRemote)
    }

    @Test(arguments: VNCTouchNavigation.allCases)
    func otherTouchCountsAreNotViewportDrags(mode: VNCTouchNavigation) {
        #expect(route(0, 2, mode) == nil)
        #expect(route(3, 2, mode) == nil)
    }
}
