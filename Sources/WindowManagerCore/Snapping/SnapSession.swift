import CoreGraphics

/// Snapping across one drag, with sticky attachments.
///
/// Feed it the frame the window would have without snapping (the "raw" frame, from the mouse),
/// on every drag event. On each axis independently:
/// - while detached, an edge that comes within the snap distance of a target attaches to it;
/// - while attached, the window stays on that target and every other target is ignored, until the
///   raw frame has pulled more than the release distance away from it. Only then is it detached,
///   and only then does it start looking for new targets.
/// That keeps a window from hopping between nearby targets while being pulled off one.
public struct SnapSession {
    public let engine: SnapEngine
    public let operation: SnapEngine.Operation
    public let others: [CGRect]
    public let screens: [CGRect]

    private var attachments: [SnapEngine.Axis: SnapEngine.Attachment] = [:]

    public init(engine: SnapEngine, operation: SnapEngine.Operation, others: [CGRect], screens: [CGRect]) {
        self.engine = engine
        self.operation = operation
        self.others = others
        self.screens = screens
    }

    /// True while any edge is held on a target.
    public var isAttached: Bool { !attachments.isEmpty }

    /// The frame the window should have for this raw frame.
    public mutating func update(_ raw: CGRect) -> CGRect {
        guard engine.distance > 0 else { return raw }
        let moving = engine.moving(operation)
        var r = raw
        // x, then y, then x again: snapping flush on y can enable corner alignment on x (stacked
        // windows lining up their sides), which the first x pass could not see yet.
        for (pass, axis) in [SnapEngine.Axis.x, .y, .x].enumerated() {
            if pass == 2 && attachments[.x] != nil { continue }
            if let a = attachments[axis], pass < 2 {
                let d = a.target - engine.edge(raw, axis, low: a.low)
                if abs(d) <= engine.releaseDistance {
                    r = engine.apply(d, axis: axis, to: r, operation: operation, moving: moving)
                    continue
                }
                attachments[axis] = nil // fully detached; free to find a new target below
            }
            // Search from the frame snapped so far, so an x attachment counts as "side by side" when
            // looking for y alignment even if the raw frame has drifted off it.
            if let a = engine.bestAttachment(axis: axis, frame: r, moving: moving, others: others, screens: screens) {
                attachments[axis] = a
                let d = a.target - engine.edge(r, axis, low: a.low)
                r = engine.apply(d, axis: axis, to: r, operation: operation, moving: moving)
            }
        }
        return r
    }
}
