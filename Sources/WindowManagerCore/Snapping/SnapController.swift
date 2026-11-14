import AppKit

/// Watches the mouse and snaps windows while the user moves or resizes them.
///
/// macOS has no "window is being dragged" event for other apps' windows, so this follows the left
/// mouse button: at mouse-down it records the window under the cursor and its frame, on every drag
/// event it compares the window's current frame with the starting one to tell a move from a resize
/// (and which edges), and when the result is within the snap distance of a target it sets the
/// snapped frame through Accessibility. The window server keeps placing the window relative to the
/// cursor, so the window stays snapped until the user drags past the distance, then lets go.
@MainActor
public final class SnapController {
    public var engine: SnapEngine
    public var isEnabled: Bool {
        didSet { isEnabled ? start() : stop() }
    }

    private let service: WindowService
    private var monitors: [Any] = []
    private var drag: DragState?

    private struct DragState {
        let windowID: CGWindowID
        let pid: pid_t
        let startFrame: CGRect
        var window: Window?
        /// Targets are gathered once per drag; other windows do not move meanwhile.
        let others: [CGRect]
        let screens: [CGRect]
        var operation: SnapEngine.Operation?
        var lastApplied: CGRect?
    }

    public init(engine: SnapEngine = SnapEngine(), isEnabled: Bool = true, service: WindowService = WindowService()) {
        self.engine = engine
        self.isEnabled = isEnabled
        self.service = service
        if isEnabled { start() }
    }

    private func start() {
        guard monitors.isEmpty else { return }
        let handlers: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.leftMouseDown, { [weak self] _ in self?.mouseDown() }),
            (.leftMouseDragged, { [weak self] _ in self?.mouseDragged() }),
            (.leftMouseUp, { [weak self] _ in self?.mouseUp() }),
        ]
        for (mask, h) in handlers {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { e in
                MainActor.assumeIsolated { h(e) }
            }) { monitors.append(m) }
        }
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        drag = nil
    }

    /// Mouse location in AX space.
    private var cursor: CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: DisplayService.primaryHeight - p.y)
    }

    private func mouseDown() {
        drag = nil
        guard AccessibilityPermission.isTrusted, let hit = WindowList.window(at: cursor) else { return }
        let others = WindowList.onScreen().filter { $0.windowID != hit.windowID }.map(\.frame)
        let screens = DisplayService.displays.flatMap { [$0.visibleFrame, $0.frame] }
        drag = DragState(windowID: hit.windowID, pid: hit.pid, startFrame: hit.frame,
                         others: others, screens: screens)
    }

    private func mouseDragged() {
        guard var d = drag, let now = WindowList.frame(of: d.windowID) else { return }
        // Lock in move vs resize on the first change, so a move that briefly reports a size change
        // (some apps round sizes) does not flip into a resize mid-drag.
        if d.operation == nil {
            guard let op = SnapEngine.Operation.detect(from: d.startFrame, to: now) else { return }
            d.operation = op
            d.window = service.window(withID: d.windowID, pid: d.pid)
        }
        guard let op = d.operation, let window = d.window else { drag = d; return }
        let snapped = engine.snap(now, operation: op, others: d.others, screens: d.screens)
        if snapped != now {
            apply(snapped, to: window, operation: op)
            d.lastApplied = snapped
        }
        drag = d
    }

    private func mouseUp() {
        // The last drag event may have been followed by a final unsnapped move; settle it.
        if let d = drag, let op = d.operation, let window = d.window, let now = WindowList.frame(of: d.windowID) {
            let snapped = engine.snap(now, operation: op, others: d.others, screens: d.screens)
            if snapped != now { apply(snapped, to: window, operation: op) }
        }
        drag = nil
    }

    private func apply(_ frame: CGRect, to window: Window, operation: SnapEngine.Operation) {
        switch operation {
        case .move:
            AX.set(window.element, kAXPositionAttribute, point: frame.origin)
        case .resize(let edges):
            if edges.contains(.left) || edges.contains(.top) {
                AX.set(window.element, kAXPositionAttribute, point: frame.origin)
            }
            AX.set(window.element, kAXSizeAttribute, size: frame.size)
        }
    }
}
