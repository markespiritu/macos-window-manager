import CoreGraphics

/// Edges of a rect, in AX space (top = minY).
public struct Edges: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = Edges(rawValue: 1)
    public static let right = Edges(rawValue: 2)
    public static let top = Edges(rawValue: 4)
    public static let bottom = Edges(rawValue: 8)
    public static let all: Edges = [.left, .right, .top, .bottom]
}

/// Linux-style magnetic snapping, as pure math. Given the frame the user is dragging a window to,
/// returns the frame it should snap to. All rects are in AX space (top-left origin, y down).
///
/// The rules follow KWin's (behaviour only; no KWin code is used, it is GPL). A moving edge snaps
/// to the nearest target within `distance`, independently on each axis:
/// - screen edges: the edges of the usable area of the display under the window's centre;
/// - neighbouring windows, edge to opposite edge, only when the two windows overlap on the other
///   axis, so windows sit flush side by side or stacked;
/// - "corner" snapping: once flush against a window on one axis, the same edges line up on the
///   other axis, so tops of side-by-side windows (and sides of stacked windows) align.
/// When moving, both edges of an axis are candidates and the whole frame shifts. When resizing,
/// only the dragged edges are candidates and only they move, so a window's bottom snaps level with
/// its neighbour's bottom.
public struct SnapEngine: Equatable, Sendable {
    public enum Operation: Equatable, Sendable {
        case move
        /// The edges being dragged.
        case resize(Edges)
    }

    public var distance: CGFloat
    /// How far an attached edge must be pulled from its target before it lets go. Larger than
    /// `distance`, so snapping does not flicker on and off at the boundary and pulling a window
    /// away is a deliberate move. Never less than `distance`.
    public var releaseDistance: CGFloat
    public var snapToScreen: Bool
    public var snapToWindows: Bool

    public init(distance: CGFloat = 10, releaseDistance: CGFloat? = nil, snapToScreen: Bool = true,
                snapToWindows: Bool = true) {
        self.distance = distance
        self.releaseDistance = max(releaseDistance ?? distance, distance)
        self.snapToScreen = snapToScreen
        self.snapToWindows = snapToWindows
    }

    /// - Parameters:
    ///   - frame: where the window is being dragged to.
    ///   - others: frames of the other visible windows.
    ///   - screens: usable (visible) frames of the displays.
    public func snap(_ frame: CGRect, operation: Operation, others: [CGRect], screens: [CGRect]) -> CGRect {
        var session = SnapSession(engine: self, operation: operation, others: others, screens: screens)
        return session.update(frame)
    }

    // MARK: - Internals

    enum Axis: CaseIterable { case x, y }

    /// An edge of the window held on a target line.
    struct Attachment: Equatable {
        let low: Bool
        let target: CGFloat
    }

    /// The edge of `r` at `low` (left/top) or high (right/bottom) end of `axis`.
    func edge(_ r: CGRect, _ axis: Axis, low: Bool) -> CGFloat {
        switch axis {
        case .x: return low ? r.minX : r.maxX
        case .y: return low ? r.minY : r.maxY
        }
    }

    /// Range of `r` across the other axis.
    private func span(_ r: CGRect, across axis: Axis) -> ClosedRange<CGFloat> {
        axis == .x ? r.minY...r.maxY : r.minX...r.maxX
    }

    /// True when two ranges overlap (touching counts).
    private func overlaps(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> Bool {
        a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound
    }

    /// True when `a` and `b` sit exactly flush along `axis` (an edge of one on the opposite edge of
    /// the other), e.g. side by side for `.x`.
    private func flush(_ a: CGRect, _ b: CGRect, along axis: Axis) -> Bool {
        abs(edge(a, axis, low: true) - edge(b, axis, low: false)) < 0.5
            || abs(edge(a, axis, low: false) - edge(b, axis, low: true)) < 0.5
    }

    /// The usable area of the display under the window's centre (else the one it overlaps most).
    private func screen(for f: CGRect, in screens: [CGRect]) -> CGRect? {
        screens.first { $0.contains(f.center) }
            ?? screens.max { $0.intersectionArea(with: f) < $1.intersectionArea(with: f) }
    }

    func moving(_ op: Operation) -> Edges {
        if case .resize(let e) = op { return e }
        return .all
    }

    func canMove(_ moving: Edges, _ axis: Axis, low: Bool) -> Bool {
        moving.contains(axis == .x ? (low ? .left : .right) : (low ? .top : .bottom))
    }

    /// The nearest target, within `distance`, for a moving edge on `axis`.
    func bestAttachment(axis: Axis, frame f: CGRect, moving: Edges, others: [CGRect],
                        screens: [CGRect]) -> Attachment? {
        let others = snapToWindows ? others.filter { !$0.isEmpty } : []
        let screens = snapToScreen ? screens : []
        var candidates: [(low: Bool, target: CGFloat)] = []
        let other: Axis = axis == .x ? .y : .x

        if let s = screen(for: f, in: screens) {
            candidates.append((true, edge(s, axis, low: true)))
            candidates.append((false, edge(s, axis, low: false)))
        }
        for o in others {
            // Opposite edges: sit flush next to the other window when they overlap across the axis.
            if overlaps(span(f, across: axis), span(o, across: axis)) {
                candidates.append((true, edge(o, axis, low: false)))
                candidates.append((false, edge(o, axis, low: true)))
            }
            // Corner snapping: line up with a window this one is already flush against.
            if flush(f, o, along: other) {
                candidates.append((true, edge(o, axis, low: true)))
                candidates.append((false, edge(o, axis, low: false)))
            }
        }

        var best: (Attachment, CGFloat)?
        for c in candidates where canMove(moving, axis, low: c.low) {
            let d = abs(c.target - edge(f, axis, low: c.low))
            if d <= distance, best == nil || d < best!.1 { best = (Attachment(low: c.low, target: c.target), d) }
        }
        return best?.0
    }

    func apply(_ d: CGFloat, axis: Axis, to r: CGRect, operation: Operation, moving: Edges) -> CGRect {
        var r = r
        switch (operation, axis) {
        case (.move, .x): r.origin.x += d
        case (.move, .y): r.origin.y += d
        case (.resize, .x):
            if moving.contains(.left) { r.origin.x += d; r.size.width -= d } else { r.size.width += d }
        case (.resize, .y):
            if moving.contains(.top) { r.origin.y += d; r.size.height -= d } else { r.size.height += d }
        }
        return r
    }
}

public extension SnapEngine.Operation {
    /// Works out what the user is doing from the frame at mouse-down and the frame now:
    /// same size means a move; otherwise the edges that changed are the ones being dragged.
    /// Returns nil when nothing changed.
    static func detect(from start: CGRect, to now: CGRect, tolerance: CGFloat = 0.5) -> Self? {
        let sameSize = abs(start.width - now.width) <= tolerance && abs(start.height - now.height) <= tolerance
        if sameSize {
            let moved = abs(start.minX - now.minX) > tolerance || abs(start.minY - now.minY) > tolerance
            return moved ? .move : nil
        }
        var e: Edges = []
        if abs(start.minX - now.minX) > tolerance { e.insert(.left) }
        if abs(start.maxX - now.maxX) > tolerance { e.insert(.right) }
        if abs(start.minY - now.minY) > tolerance { e.insert(.top) }
        if abs(start.maxY - now.maxY) > tolerance { e.insert(.bottom) }
        return e.isEmpty ? nil : .resize(e)
    }
}
