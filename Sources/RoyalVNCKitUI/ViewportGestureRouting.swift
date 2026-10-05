import CoreGraphics

/// How touches split between the remote screen and the local viewport.
/// Persisted by raw value under `AppSettingKeys.vncTouchNavigation`.
public enum VNCTouchNavigation: String, CaseIterable, Sendable {
    /// One finger always acts on the remote; only two fingers pan and zoom.
    case twoFinger
    /// One finger pans the viewport when zoomed in; two fingers scroll the remote.
    case classic
}

enum ViewportDragAction: Equatable {
    case moveRemotePointer
    case panViewport
    case scrollRemote
}

enum ViewportGestureRouting {
    /// Above this scale the framebuffer is bigger than the view and can be panned.
    static let zoomedInScaleThreshold: CGFloat = 1.01

    static func dragAction(
        touchCount: Int,
        viewportScale: CGFloat,
        navigation: VNCTouchNavigation
    ) -> ViewportDragAction? {
        let isZoomedIn = viewportScale > zoomedInScaleThreshold
        switch (touchCount, navigation) {
        case (1, .twoFinger):
            return .moveRemotePointer
        case (1, .classic):
            return isZoomedIn ? .panViewport : .moveRemotePointer
        case (2, .twoFinger):
            // Nothing to pan when not zoomed in, so the drag scrolls the remote.
            return isZoomedIn ? .panViewport : .scrollRemote
        case (2, .classic):
            return .scrollRemote
        default:
            return nil
        }
    }
}
