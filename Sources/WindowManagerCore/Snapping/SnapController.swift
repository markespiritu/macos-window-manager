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
/// - Once the move or resize is recognised, the tap swallows every further drag event and this
///   controller places the window itself (mouse-derived frame, snapped) for the rest of the drag,
///   the way a Linux window manager owns interactive moves. macOS and the snapper never take turns
///   moving the window, so it cannot jump between the two.
@MainActor
public final class SnapController {
    public var engine: SnapEngine
    /// Runs the event tap. True when snapping or zones are on.
    public var isEnabled: Bool {
        didSet { isEnabled ? start() : stop() }
    }
    /// Edge snapping. When off, drags are left to macOS (zones still work for moves).
    public var snapping = true
    /// Zones shown while moving a window (Shift held, by default).
    public var zones: ZoneController?
    /// False until the event tap exists (it needs the Accessibility permission).
    public private(set) var isRunning = false

    private let service: WindowService
    private let placer = WindowPlacer()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var drag: DragState?

    private struct DragState {
        let windowID: CGWindowID
        let pid: pid_t
        var startFrame: CGRect
        let startMouse: CGPoint
        var window: Window?
        var session: SnapSession?
        /// The frame this controller last gave the window.
        var placed: CGRect?
        /// True when this controller moves the window itself (snapping on); false when macOS does.
        var owns = false
        /// The window's size changes on the next placement (restoring its pre-zone size).
        var resize = false
        var mouse: CGPoint
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
            | (1 << CGEventType.flagsChanged.rawValue)
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
        zones?.cancelDrag()
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
            return mouseDragged(to: event.location, flags: event.flags)
        case .leftMouseUp:
            mouseUp(at: event.location, flags: event.flags)
            return true
        case .flagsChanged:
            // Pressing or releasing Shift / Ctrl mid-drag shows, hides or spans zones at once,
            // without waiting for the mouse to move.
            if let d = drag, d.session?.operation == .move { zones?.update(mouse: d.mouse, flags: event.flags) }
            return true
        default:
            return true
        }
    }

    private func mouseDown(at point: CGPoint) {
        drag = nil
        zones?.cancelDrag()
        // This app's own windows (Settings) are snap targets but are left to macOS to drag: asking
        // our own process for its windows over Accessibility from inside the event tap callback
        // would wait on the very thread that is running the callback.
        guard let hit = WindowList.window(at: point, margin: 6),
              hit.pid != ProcessInfo.processInfo.processIdentifier else { return }
        drag = DragState(windowID: hit.windowID, pid: hit.pid, startFrame: hit.frame, startMouse: point, mouse: point)
    }

    private func mouseDragged(to mouse: CGPoint, flags: CGEventFlags) -> Bool {
        guard var d = drag else { return true }
        d.mouse = mouse

        if d.session == nil {
            // Wait for the window to start changing to know whether this is a move or a resize.
            guard let now = WindowList.frame(of: d.windowID),
                  let op = SnapEngine.Operation.detect(from: d.startFrame, to: now) else { drag = d; return true }
            // Without snapping only moves matter (for zones), and macOS keeps doing the dragging.
            guard snapping || (op == .move && zones != nil) else { drag = nil; return true }
            // Only take over windows we can actually place; otherwise leave the drag to macOS.
            guard let window = service.window(withID: d.windowID, pid: d.pid),
                  op == .move ? window.isMovable : window.isResizable else { drag = nil; return true }
            d.window = window
            d.owns = snapping
            if op == .move {
                zones?.beginDrag()
                // A window dragged out of a zone gets its old size back, keeping the point under
                // the cursor at the same relative spot across the title bar.
                if d.owns, let size = zones?.takeRestoreSize(d.windowID, current: d.startFrame) {
                    let s = d.startFrame
                    let x = d.startMouse.x - (d.startMouse.x - s.minX) * size.width / max(s.width, 1)
                    d.startFrame = CGRect(x: x, y: s.minY, width: size.width, height: size.height)
                    d.resize = true
                }
            }
            let others = WindowList.onScreen().filter { $0.windowID != d.windowID }.map(\.frame)
            let screens = DisplayService.displays.map(\.visibleFrame)
            d.session = SnapSession(engine: engine, operation: op, others: others, screens: screens)
        }
        guard var session = d.session, let window = d.window else { drag = d; return true }

        // From here on this controller is the only thing moving the window, like a Linux window
        // manager: every drag event is swallowed and the window is placed at the mouse-derived frame,
        // snapped. There is no hand-over between macOS and the snapper, so nothing jumps.
        let raw = Self.rawFrame(start: d.startFrame, operation: session.operation,
                                dx: mouse.x - d.startMouse.x, dy: mouse.y - d.startMouse.y)
        let inZones = session.operation == .move && zones?.update(mouse: mouse, flags: flags) != nil
        guard d.owns else { drag = d; return true }
        // Over zones the window just follows the mouse; it goes into the zone on release.
        let target = inZones ? raw : session.update(raw)
        d.session = session
        if target != d.placed {
            place(window, at: target, operation: d.resize ? .resize([.left, .top]) : session.operation)
            d.resize = false
        }
        d.placed = target
        drag = d
        return false
    }

    /// Places the window one last time for where the mouse was released (a fast drag that stops
    /// next to an edge still snaps), then lets the release through so the app ends its drag.
    private func mouseUp(at mouse: CGPoint, flags: CGEventFlags) {
        defer { drag = nil }
        guard let d = drag, var session = d.session, let window = d.window else { return }
        if session.operation == .move, let zone = zones?.endDrag(mouse: mouse, flags: flags) {
            if d.owns {
                placer.place(window, frame: zone)
            } else {
                // macOS is still ending its own drag; place the window once it has let go.
                let placer = placer
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { placer.place(window, frame: zone) }
            }
            zones?.didZone(d.windowID, original: d.startFrame.size, placed: zone)
            return
        }
        guard d.owns else { return }
        let raw = Self.rawFrame(start: d.startFrame, operation: session.operation,
                                dx: mouse.x - d.startMouse.x, dy: mouse.y - d.startMouse.y)
        let target = session.update(raw)
        if target != d.placed { place(window, at: target, operation: session.operation) }
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
        placer.place(window, at: frame, operation: operation)
    }
}

/// Sets window frames off the main thread. An Accessibility call is a round trip to the other
/// app and can take milliseconds; doing it inside the event tap callback held up every mouse event
/// system-wide, which made the cursor and the drag stutter. Requests are coalesced: while one is
/// in flight only the newest pending frame is kept, so a slow app gets the latest position rather
/// than a backlog.
final class WindowPlacer: @unchecked Sendable {
    private struct Request {
        let window: Window
        let frame: CGRect
        /// nil: set position and size (a window going into a zone).
        let operation: SnapEngine.Operation?
    }

    private let queue = DispatchQueue(label: "io.marky.windowmanager.placer", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: Request?
    private var draining = false

    func place(_ window: Window, frame: CGRect) {
        enqueue(Request(window: window, frame: frame, operation: nil))
    }

    func place(_ window: Window, at frame: CGRect, operation: SnapEngine.Operation) {
        enqueue(Request(window: window, frame: frame, operation: operation))
    }

    private func enqueue(_ request: Request) {
        lock.lock()
        // Never let a plain move overwrite a pending request that also sets the size (the first
        // placement after restoring a window's pre-zone size), or the new size would be lost.
        if let p = pending, p.operation != .move, request.operation == .move {
            pending = Request(window: request.window, frame: request.frame, operation: p.operation)
        } else {
            pending = request
        }
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let r = pending else { draining = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            apply(r)
        }
    }

    private func apply(_ r: Request) {
        switch r.operation {
        case nil:
            // Size, position, size, as in WindowService.setFrame: fits the window at the new
            // position, then fixes a size the app clamped at the old one.
            AX.set(r.window.element, kAXSizeAttribute, size: r.frame.size)
            AX.set(r.window.element, kAXPositionAttribute, point: r.frame.origin)
            AX.set(r.window.element, kAXSizeAttribute, size: r.frame.size)
        case .move:
            AX.set(r.window.element, kAXPositionAttribute, point: r.frame.origin)
        case .resize(let edges):
            if edges.contains(.left) || edges.contains(.top) {
                AX.set(r.window.element, kAXPositionAttribute, point: r.frame.origin)
            }
            AX.set(r.window.element, kAXSizeAttribute, size: r.frame.size)
        }
    }
}
