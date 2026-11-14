import AppKit

/// Watches the mouse and snaps windows while the user moves or resizes them.
///
/// macOS has no "window is being dragged" event for other apps' windows, so this follows the left
/// mouse button through an event tap:
/// - At mouse-down it records the window under the cursor and its frame.
/// - On the first drag event that changes that window's frame, it decides between a move and a
///   resize (and which edges), and starts a `SnapSession`.
/// - From then on, the raw frame comes from the mouse (start frame + mouse travel), never from the
///   window, so snapping does not feed back into itself.
/// - While an edge is attached, the tap swallows the drag events so the window server stops moving
///   the window, and this places the window itself. That avoids the window being pulled to the raw
///   position and pushed back to the snapped one on every event. When nothing is attached, events
///   pass through and macOS drags the window as usual.
@MainActor
public final class SnapController {
    public var engine: SnapEngine
    public var isEnabled: Bool {
        didSet { isEnabled ? start() : stop() }
    }
    /// False until the event tap exists (it needs the Accessibility permission).
    public private(set) var isRunning = false

    private let service: WindowService
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var drag: DragState?

    private struct DragState {
        let windowID: CGWindowID
        let pid: pid_t
        let startFrame: CGRect
        let startMouse: CGPoint
        var window: Window?
        var session: SnapSession?
        /// The frame this controller last gave the window.
        var placed: CGRect?
    }

    public init(engine: SnapEngine = SnapEngine(), isEnabled: Bool = true, service: WindowService = WindowService()) {
        self.engine = engine
        self.isEnabled = isEnabled
        self.service = service
        if isEnabled { start() }
    }

    /// Creates the event tap if it is not running yet. Safe to call again, e.g. once the
    /// Accessibility permission is granted.
    public func start() {
        guard isEnabled, tap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, ctx in
            let controller = Unmanaged<SnapController>.fromOpaque(ctx!).takeUnretainedValue()
            let keep = MainActor.assumeIsolated { controller.handle(type, event) }
            return keep ? Unmanaged.passUnretained(event) : nil
        }, userInfo: me) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        drag = nil
        isRunning = false
    }

    /// Returns false to swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .leftMouseDown:
            mouseDown(at: event.location)
            return true
        case .leftMouseDragged:
            return mouseDragged(to: event.location)
        case .leftMouseUp:
            drag = nil
            return true
        default:
            return true
        }
    }

    private func mouseDown(at point: CGPoint) {
        drag = nil
        guard let hit = WindowList.window(at: point, margin: 6) else { return }
        drag = DragState(windowID: hit.windowID, pid: hit.pid, startFrame: hit.frame, startMouse: point)
    }

    private func mouseDragged(to mouse: CGPoint) -> Bool {
        guard var d = drag else { return true }
        defer { drag = d }

        if d.session == nil {
            // Wait for the window to start changing to know whether this is a move or a resize.
            guard let now = WindowList.frame(of: d.windowID),
                  let op = SnapEngine.Operation.detect(from: d.startFrame, to: now) else { return true }
            guard let window = service.window(withID: d.windowID, pid: d.pid) else { drag = nil; return true }
            d.window = window
            let others = WindowList.onScreen().filter { $0.windowID != d.windowID }.map(\.frame)
            let screens = DisplayService.displays.flatMap { [$0.visibleFrame, $0.frame] }
            d.session = SnapSession(engine: engine, operation: op, others: others, screens: screens)
        }
        guard var session = d.session, let window = d.window else { return true }

        let raw = Self.rawFrame(start: d.startFrame, operation: session.operation,
                                dx: mouse.x - d.startMouse.x, dy: mouse.y - d.startMouse.y)
        let target = session.update(raw)
        d.session = session

        if session.isAttached {
            if target != d.placed { place(window, at: target, operation: session.operation) }
            d.placed = target
            return false // hold the window ourselves
        }
        if d.placed != nil {
            // Just detached: put the window back under the cursor, then let macOS carry on.
            place(window, at: raw, operation: session.operation)
            d.placed = nil
        }
        return true
    }

    /// Where the window would be without snapping: the start frame plus the mouse travel, applied
    /// to the whole frame for a move and to the dragged edges for a resize.
    nonisolated static func rawFrame(start: CGRect, operation: SnapEngine.Operation, dx: CGFloat, dy: CGFloat) -> CGRect {
        switch operation {
        case .move:
            return start.offsetBy(dx: dx, dy: dy)
        case .resize(let e):
            var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
            if e.contains(.left) { minX += dx }
            if e.contains(.right) { maxX += dx }
            if e.contains(.top) { minY += dy }
            if e.contains(.bottom) { maxY += dy }
            return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        }
    }

    private func place(_ window: Window, at frame: CGRect, operation: SnapEngine.Operation) {
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
