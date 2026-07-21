import CoreGraphics

struct KeyboardToolbarGeometry {
    static func bottomOverlapHeight(viewBounds: CGRect, keyboardFrame: CGRect) -> CGFloat {
        let intersection = viewBounds.intersection(keyboardFrame)
        guard !intersection.isNull,
              !intersection.isEmpty,
              intersection.maxY >= viewBounds.maxY - 1 else {
            return 0
        }

        return intersection.height
    }
}
