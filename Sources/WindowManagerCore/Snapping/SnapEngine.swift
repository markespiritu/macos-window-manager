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
/// The rules follow KWin's (behaviour only; no KWin code is used, it is GPL). Like KWin there are
/// three zones, each with its own distance. A moving edge snaps to the nearest target within its
/// zone's distance, independently on each axis:
/// - screen edges (`screenDistance`): the edges of the usable area of the display under the
///   window's centre;
/// - neighbouring windows, edge to opposite edge, only when the two windows overlap on the other
///   axis, so windows sit flush side by side or stacked;
/// - "corner" snapping: once flush against a window on one axis, the same edges line up on the
///   other axis, so tops of side-by-side windows (and sides of stacked windows) align
///   (`windowDistance` for both window rules);
/// - screen centre (`centerDistance`, moves only, off by default): the window centres on the
///   display when its centre comes within the distance on both axes, or centres along a screen
///   edge it is already snapped to (top/bottom edge: horizontally; left/right edge: vertically).
/// When moving, both edges of an axis are candidates and the whole frame shifts. When resizing,
/// only the dragged edges are candidates and only they move, so a window's bottom snaps level with
/// its neighbour's bottom.
public struct SnapEngine: Equatable, Sendable {
    public enum Operation: Equatable, Sendable {
        case move
        /// The edges being dragged.
        case resize(Edges)
    }

    /// Catch distance for screen edges.
    public var screenDistance: CGFloat
    /// Catch distance for other windows' edges.
    public var windowDistance: CGFloat
    /// Catch distance for the screen centre.
    public var centerDistance: CGFloat
    public var snapToScreen: Bool
    public var snapToWindows: Bool
    public var snapToCenter: Bool

    public init(screenDistance: CGFloat = 10, windowDistance: CGFloat = 10, centerDistance: CGFloat = 10,
                snapToScreen: Bool = true, snapToWindows: Bool = true,
                snapToCenter: Bool = false) {
        self.screenDistance = screenDistance
        self.windowDistance = windowDistance
        self.centerDistance = centerDistance
        self.snapToScreen = snapToScreen
        self.snapToWindows = snapToWindows
        self.snapToCenter = snapToCenter
    }

    /// Same distance for every zone (handy in tests and the debug CLI).
    public init(distance: CGFloat, snapToScreen: Bool = true,
                snapToWindows: Bool = true, snapToCenter: Bool = false) {
        self.init(screenDistance: distance, windowDistance: distance, centerDistance: distance,
                  snapToScreen: snapToScreen,
                  snapToWindows: snapToWindows, snapToCenter: snapToCenter)
    }

    /// True when at least one zone can catch anything.
    var isActive: Bool {
        (snapToScreen && screenDistance > 0) || (snapToWindows && windowDistance > 0)
            || (snapToCenter && centerDistance > 0)
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

    /// Which line of the window is held: its low edge (left/top), high edge (right/bottom) or
    /// centre.
    enum Anchor: Equatable { case low, high, center }

    /// A line of the window held on a target line, and the catch distance of the zone it came from.
    struct Attachment: Equatable {
        let anchor: Anchor
        let target: CGFloat
        let zone: CGFloat
    }

    /// The edge of `r` at `low` (left/top) or high (right/bottom) end of `axis`.
    func edge(_ r: CGRect, _ axis: Axis, low: Bool) -> CGFloat {
        switch axis {
        case .x: return low ? r.minX : r.maxX
        case .y: return low ? r.minY : r.maxY
        }
    }

    /// The line of `r` an anchor refers to on `axis`.
    func line(_ r: CGRect, _ axis: Axis, _ anchor: Anchor) -> CGFloat {
        switch anchor {
        case .low: return edge(r, axis, low: true)
        case .high: return edge(r, axis, low: false)
        case .center: return axis == .x ? r.midX : r.midY
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

    func canMove(_ moving: Edges, _ axis: Axis, _ anchor: Anchor) -> Bool {
        switch anchor {
        case .low: return moving.contains(axis == .x ? .left : .top)
        case .high: return moving.contains(axis == .x ? .right : .bottom)
        case .center: return moving == .all // centring moves the whole window
        }
    }

    /// The nearest target, within its zone's distance, for a moving line of the window on `axis`.
    func bestAttachment(axis: Axis, frame f: CGRect, moving: Edges, others: [CGRect],
                        screens: [CGRect]) -> Attachment? {
        var candidates: [Attachment] = []
        let other: Axis = axis == .x ? .y : .x
        let display = screen(for: f, in: screens)

        if snapToScreen, let s = display {
            candidates.append(Attachment(anchor: .low, target: edge(s, axis, low: true), zone: screenDistance))
            candidates.append(Attachment(anchor: .high, target: edge(s, axis, low: false), zone: screenDistance))
        }
        if snapToWindows {
            for o in others where !o.isEmpty {
                // Opposite edges: sit flush next to the other window when they overlap across the axis.
                if overlaps(span(f, across: axis), span(o, across: axis)) {
                    candidates.append(Attachment(anchor: .low, target: edge(o, axis, low: false), zone: windowDistance))
                    candidates.append(Attachment(anchor: .high, target: edge(o, axis, low: true), zone: windowDistance))
                }
                // Corner snapping: line up with a window this one is already flush against.
                if flush(f, o, along: other) {
                    candidates.append(Attachment(anchor: .low, target: edge(o, axis, low: true), zone: windowDistance))
                    candidates.append(Attachment(anchor: .high, target: edge(o, axis, low: false), zone: windowDistance))
                }
            }
        }
        // Screen centre: the window's centre line on this axis goes to the display's centre line
        // when it is also near the centre on the other axis (centre of the screen), or when it is
        // snapped to a screen edge on the other axis (centre along that edge).
        if snapToCenter, let s = display {
            let nearOtherCentre = abs(line(f, other, .center) - line(s, other, .center)) <= centerDistance
            let onOtherEdge = abs(edge(f, other, low: true) - edge(s, other, low: true)) < 0.5
                || abs(edge(f, other, low: false) - edge(s, other, low: false)) < 0.5
            if nearOtherCentre || onOtherEdge {
                candidates.append(Attachment(anchor: .center, target: line(s, axis, .center), zone: centerDistance))
            }
        }

        var best: (Attachment, CGFloat)?
        for c in candidates where canMove(moving, axis, c.anchor) {
            let d = abs(c.target - line(f, axis, c.anchor))
            if d <= c.zone, best == nil || d < best!.1 { best = (c, d) }
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

    /// How close to a window corner, along each edge, a grab counts as a corner grab. macOS's own
    /// corner resize area reaches about this far from the corner.
    static let cornerReach: CGFloat = 16

    /// Like `detect(from:to:)`, but also uses where the window was grabbed. The first frame change
    /// of a corner drag often moves only one edge (the mouse went a little sideways before it went
    /// down), which would lock the whole drag onto that one edge. A resize grabbed near a corner
    /// gets that corner's other edge too, so both dimensions follow the mouse.
    static func detect(from start: CGRect, to now: CGRect, grabbedAt mouse: CGPoint,
                       tolerance: CGFloat = 0.5) -> Self? {
        guard case .resize(var e)? = detect(from: start, to: now, tolerance: tolerance) else {
            return detect(from: start, to: now, tolerance: tolerance)
        }
        let reach = cornerReach
        let nearLeft = abs(mouse.x - start.minX) <= reach, nearRight = abs(mouse.x - start.maxX) <= reach
        let nearTop = abs(mouse.y - start.minY) <= reach, nearBottom = abs(mouse.y - start.maxY) <= reach
        let hasX = !e.isDisjoint(with: [.left, .right]), hasY = !e.isDisjoint(with: [.top, .bottom])
        if hasX && !hasY {
            let xNear = e.contains(.left) ? nearLeft : nearRight
            if xNear && nearTop != nearBottom { e.insert(nearTop ? .top : .bottom) }
        } else if hasY && !hasX {
            let yNear = e.contains(.top) ? nearTop : nearBottom
            if yNear && nearLeft != nearRight { e.insert(nearLeft ? .left : .right) }
        }
        return .resize(e)
    }
}
