import CoreGraphics

/// Snapping across one drag, KWin style: no memory between mouse movements.
///
/// Feed it the frame the window would have without snapping (the "raw" frame, from the mouse),
/// on every drag event. Each call works the snap out from scratch: on each axis the nearest target
/// within its zone's distance wins, so a window lets go of a target at the same distance it caught
/// it, and moves straight to a nearer target when there is one.
public struct SnapSession {
    public let engine: SnapEngine
    public let operation: SnapEngine.Operation
    public let others: [CGRect]
    public let screens: [CGRect]

    /// What the last update snapped to, per axis.
    private var attachments: [SnapEngine.Axis: SnapEngine.Attachment] = [:]

    public init(engine: SnapEngine, operation: SnapEngine.Operation, others: [CGRect], screens: [CGRect]) {
        self.engine = engine
        self.operation = operation
        self.others = others
        self.screens = screens
    }

    /// True when the last update snapped anything.
    public var isAttached: Bool { !attachments.isEmpty }

    /// The frame the window should have for this raw frame.
    public mutating func update(_ raw: CGRect) -> CGRect {
        attachments = [:]
        guard engine.isActive else { return raw }
        let moving = engine.moving(operation)
        var r = raw
        // x, then y, then x again: snapping flush on y can enable corner alignment on x (stacked
        // windows lining up their sides), which the first x pass could not see yet. Each search
        // starts from the frame snapped so far, so an x snap counts as "side by side" when looking
        // for y alignment.
        for (pass, axis) in [SnapEngine.Axis.x, .y, .x].enumerated() {
            if pass == 2 && attachments[.x] != nil { continue }
            if let a = engine.bestAttachment(axis: axis, frame: r, moving: moving, others: others, screens: screens) {
                attachments[axis] = a
                let d = a.target - engine.line(r, axis, a.anchor)
                r = engine.apply(d, axis: axis, to: r, operation: operation, moving: moving)
            }
        }
        return r
    }
}
