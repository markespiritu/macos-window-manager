import AppKit

/// A display, with frames already converted to AX space so callers never handle the AppKit flip.
public struct Display: Identifiable, CustomStringConvertible {
    public let id: CGDirectDisplayID
    public let name: String
    /// Whole display, AX space.
    public let frame: CGRect
    /// Area not covered by the menu bar and Dock, AX space.
    public let visibleFrame: CGRect
    public let isMain: Bool

    public var description: String {
        let f = visibleFrame
        return "\(name) | id \(id)\(isMain ? " (primary)" : "") | visible \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
    }
}

public enum DisplayService {
    /// Height of the primary display, the reference for the AppKit <-> AX flip.
    public static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    public static var displays: [Display] {
        let h = primaryHeight
        return NSScreen.screens.enumerated().map { i, s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return Display(id: id, name: s.localizedName,
                           frame: ScreenCoordinates.flip(s.frame, primaryHeight: h),
                           visibleFrame: ScreenCoordinates.flip(s.visibleFrame, primaryHeight: h),
                           isMain: i == 0)
        }
    }

    /// The display a rect is mostly on (largest overlap), falling back to the one under its center.
    public static func display(for rect: CGRect, in displays: [Display] = displays) -> Display? {
        let best = displays.max { $0.frame.intersectionArea(with: rect) < $1.frame.intersectionArea(with: rect) }
        if let best, best.frame.intersectionArea(with: rect) > 0 { return best }
        return displays.first { $0.frame.contains(rect.center) } ?? displays.first
    }
}
