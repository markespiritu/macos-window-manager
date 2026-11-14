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
/// A moving edge snaps to the nearest target within `distance`, independently on each axis:
/// - screen edges: the inside edges of the visible area (and the full display frame);
/// - neighbouring windows, edge to opposite edge, so windows sit flush side by side or stacked;
/// - neighbouring windows, edge to same edge, when the windows touch on the other axis, so tops
///   of side-by-side windows line up (and lefts of stacked windows). Together with the previous
///   rule this makes corners meet.
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
    public var snapToScreen: Bool
    public var snapToWindows: Bool

    public init(distance: CGFloat = 15, snapToScreen: Bool = true, snapToWindows: Bool = true) {
        self.distance = distance
        self.snapToScreen = snapToScreen
        self.snapToWindows = snapToWindows
    }

    /// - Parameters:
    ///   - frame: where the window is being dragged to.
    ///   - others: frames of the other visible windows.
    ///   - screens: visible frames (and optionally full frames) of the displays.
    public func snap(_ frame: CGRect, operation: Operation, others: [CGRect], screens: [CGRect]) -> CGRect {
        guard distance > 0 else { return frame }
        let moving: Edges
        switch operation {
        case .move: moving = .all
        case .resize(let e): moving = e
        }
        let others = snapToWindows ? others.filter { !$0.isEmpty } : []
        let screens = snapToScreen ? screens : []

        var r = frame
        if let dx = bestDelta(axis: .x, frame: frame, moving: moving, others: others, screens: screens) {
            r = apply(dx, axis: .x, to: r, operation: operation, moving: moving)
        }
        if let dy = bestDelta(axis: .y, frame: frame, moving: moving, others: others, screens: screens) {
            r = apply(dy, axis: .y, to: r, operation: operation, moving: moving)
        }
        return r
    }

    // MARK: - Internals

    enum Axis { case x, y }

    /// The edge of `r` at `low` (left/top) or high (right/bottom) end of `axis`.
    private func edge(_ r: CGRect, _ axis: Axis, low: Bool) -> CGFloat {
        switch axis {
        case .x: return low ? r.minX : r.maxX
        case .y: return low ? r.minY : r.maxY
        }
    }

    /// Range of `r` across the other axis.
    private func span(_ r: CGRect, across axis: Axis) -> ClosedRange<CGFloat> {
        axis == .x ? r.minY...r.maxY : r.minX...r.maxX
    }

    /// True when two ranges overlap or are within `distance` of each other.
    private func near(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> Bool {
        a.lowerBound <= b.upperBound + distance && b.lowerBound <= a.upperBound + distance
    }

    /// True when `a` and `b` touch along `axis` (an edge of one within `distance` of the opposite
    /// edge of the other), e.g. side by side for `.x`.
    private func touching(_ a: CGRect, _ b: CGRect, along axis: Axis) -> Bool {
        abs(edge(a, axis, low: true) - edge(b, axis, low: false)) <= distance
            || abs(edge(a, axis, low: false) - edge(b, axis, low: true)) <= distance
    }

    /// Smallest signed shift, within `distance`, that puts a moving edge on a target on `axis`.
    private func bestDelta(axis: Axis, frame f: CGRect, moving: Edges, others: [CGRect],
                           screens: [CGRect]) -> CGFloat? {
        let lowEdge: Edges = axis == .x ? .left : .top
        let highEdge: Edges = axis == .x ? .right : .bottom
        var candidates: [(low: Bool, target: CGFloat)] = []
        let other: Axis = axis == .x ? .y : .x

        for s in screens where near(span(f, across: axis), span(s, across: axis)) {
            candidates.append((true, edge(s, axis, low: true)))
            candidates.append((false, edge(s, axis, low: false)))
        }
        for o in others {
            // Opposite edges: sit flush next to the other window when they overlap across the axis.
            if near(span(f, across: axis), span(o, across: axis)) {
                candidates.append((true, edge(o, axis, low: false)))
                candidates.append((false, edge(o, axis, low: true)))
            }
            // Same edges: line up with a window this one touches on the other axis.
            if touching(f, o, along: other) {
                candidates.append((true, edge(o, axis, low: true)))
                candidates.append((false, edge(o, axis, low: false)))
            }
        }

        var best: CGFloat?
        for c in candidates {
            guard moving.contains(c.low ? lowEdge : highEdge) else { continue }
            let d = c.target - edge(f, axis, low: c.low)
            if abs(d) <= distance, best == nil || abs(d) < abs(best!) { best = d }
        }
        // A delta of 0 still counts: the edge is already aligned, and that holds the window still
        // rather than letting a second, farther target pull it.
        return best
    }

    private func apply(_ d: CGFloat, axis: Axis, to r: CGRect, operation: Operation, moving: Edges) -> CGRect {
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
