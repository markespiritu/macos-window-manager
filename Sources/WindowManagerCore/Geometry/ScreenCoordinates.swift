import CoreGraphics

/// The app works in one coordinate space everywhere: the Accessibility / CoreGraphics "global" space,
/// with the origin at the top-left of the primary display and y growing downward. AppKit (`NSScreen`)
/// uses a bottom-left origin, so convert at the edge where screen frames come in.
public enum ScreenCoordinates {
    /// Converts a rect between AppKit (bottom-left origin) and AX (top-left origin) space.
    /// The flip is its own inverse, so the same function works in both directions.
    /// - Parameter primaryHeight: height of the primary display (the one at AppKit origin 0,0).
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

public extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Rounds to whole points so windows land on pixel boundaries and halves add up exactly.
    var integralized: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }

    /// Area of overlap with `other` (0 when disjoint). Used to pick the screen a window is "on".
    func intersectionArea(with other: CGRect) -> CGFloat {
        let i = intersection(other)
        return i.isNull ? 0 : i.width * i.height
    }
}
