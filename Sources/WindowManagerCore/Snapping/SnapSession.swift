import CoreGraphics

/// Snapping across one drag, with sticky attachments.
///
/// Feed it the frame the window would have without snapping (the "raw" frame, from the mouse),
/// on every drag event. On each axis independently:
/// - while detached, an edge (or the centre) that comes within its zone's distance of a target
///   attaches to it;
/// - while attached, the window stays on that target and every other target is ignored, until the
///   raw frame has pulled more than that zone's distance away from it (catch and release use the
///   same distance, as in KWin). Only then is it detached, and only then does it start looking
///   for new targets.
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
        guard engine.isActive else { return raw }
        let moving = engine.moving(operation)
        var r = raw
        if let c = engine.screenCentre(for: raw, operation: operation, screens: screens) {
            attachments[.x] = c.x
            attachments[.y] = c.y
        }
        // x, then y, then x again: snapping flush on y can enable corner alignment on x (stacked
        // windows lining up their sides), which the first x pass could not see yet.
        for (pass, axis) in [SnapEngine.Axis.x, .y, .x].enumerated() {
            if pass == 2 && attachments[.x] != nil { continue }
            if let a = attachments[axis], pass < 2 {
                let d = a.target - engine.line(raw, axis, a.anchor)
                if abs(d) <= a.zone || a.isBeyond(engine.line(raw, axis, a.anchor)) {
                    r = engine.apply(d, axis: axis, to: r, operation: operation, moving: moving)
                    continue
                }
                attachments[axis] = nil // fully detached; free to find a new target below
            }
            // Search from the frame snapped so far, so an x attachment counts as "side by side" when
            // looking for y alignment even if the raw frame has drifted off it.
            if let a = engine.bestAttachment(axis: axis, frame: r, moving: moving, others: others, screens: screens) {
                attachments[axis] = a
                let d = a.target - engine.line(r, axis, a.anchor)
                r = engine.apply(d, axis: axis, to: r, operation: operation, moving: moving)
            }
        }
        return r
    }
}
