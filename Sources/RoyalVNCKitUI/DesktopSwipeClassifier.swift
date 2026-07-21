import CoreGraphics

enum DesktopSwipeAction: Equatable {
    case missionControl
    case appExpose
}

struct DesktopSwipeClassifier {
    static let minimumTranslation: CGFloat = 70
    static let minimumVelocity: CGFloat = 300
    static let verticalDominanceRatio: CGFloat = 1.4

    static func action(
        translation: CGPoint,
        velocity: CGPoint,
        touchCount: Int,
        allTouchesDownBeforeMovement: Bool
    ) -> DesktopSwipeAction? {
        guard (3...4).contains(touchCount), allTouchesDownBeforeMovement else {
            return nil
        }

        let verticalDistance = abs(translation.y)
        let horizontalDistance = abs(translation.x)
        guard verticalDistance >= minimumTranslation,
              abs(velocity.y) >= minimumVelocity,
              verticalDistance >= horizontalDistance * verticalDominanceRatio else {
            return nil
        }

        return translation.y < 0 ? .missionControl : .appExpose
    }
}
