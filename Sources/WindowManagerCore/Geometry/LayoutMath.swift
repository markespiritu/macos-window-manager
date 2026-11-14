import CoreGraphics

/// Pure frame math for window actions. All rects are in AX space (top-left origin, y down).
/// Kept free of system calls so it can be unit tested and reused by layouts and tiling later.
public enum LayoutMath {
    /// The target frame for `action`, given the usable area of the window's screen and the window's
    /// current frame. Returns nil for actions that do not compute a frame here (e.g. `.restore`).
    /// - Parameter gap: space kept between the window and the screen edges, and between halves.
    public static func frame(for action: WindowAction, visibleFrame v: CGRect, current: CGRect,
                             gap: CGFloat = 0) -> CGRect? {
        let area = v.insetBy(dx: gap, dy: gap)
        let halfGap = gap / 2
        let r: CGRect
        switch action {
        case .leftHalf:
            let w = (area.width / 2 - halfGap).rounded(.down)
            r = CGRect(x: area.minX, y: area.minY, width: w, height: area.height)
        case .rightHalf:
            let w = (area.width / 2 - halfGap).rounded(.down)
            r = CGRect(x: area.maxX - w, y: area.minY, width: w, height: area.height)
        case .topHalf:
            let h = (area.height / 2 - halfGap).rounded(.down)
            r = CGRect(x: area.minX, y: area.minY, width: area.width, height: h)
        case .bottomHalf:
            let h = (area.height / 2 - halfGap).rounded(.down)
            r = CGRect(x: area.minX, y: area.maxY - h, width: area.width, height: h)
        case .maximize:
            r = area
        case .center:
            let w = min(current.width, area.width)
            let h = min(current.height, area.height)
            r = CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
        case .restore:
            return nil
        }
        return r.integralized
    }
}
