import AppKit
import os

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
    /// Held during a move or resize, turns snapping off until it is released, so a window can sit
    /// a few points from an edge or another window. nil: no key.
    public var bypassKey: ModifierKey?
    /// Zones shown while moving a window (Shift held, by default).
    public var zones: ZoneController?
    /// False until the event tap exists (it needs the Accessibility permission).
    public private(set) var isRunning = false

    private let service: WindowService
    private let placer = WindowPlacer()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var drag: DragState?
    /// Bumped on every mouse-down, so release checks from an earlier drag stand down.
    private var dragGeneration = 0
    private static let releaseLog = Logger(subsystem: "io.marky.windowmanager", category: "release")

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
        /// Snap edges while placing (snapping on). An owned drag without it only follows the mouse.
        var snaps = false
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
        if drag?.owns == true { placer.endDrag() }
        drag = nil
        zones?.cancelDrag()
        isRunning = false
    }

    /// Returns false to swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard DragTrace.enabled else { return dispatch(type, event) }
        let t = CFAbsoluteTimeGetCurrent()
        let keep = dispatch(type, event)
        let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
        DragTrace.tap(type, ms: ms, ageMs: (Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) - Double(event.timestamp)) / 1e6)
        return keep
    }

    private func dispatch(_ type: CGEventType, _ event: CGEvent) -> Bool {
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
            // Pressing or releasing a modifier mid-drag shows, hides or spans zones, or turns
            // snapping off or back on, at once, without waiting for the mouse to move.
            modifiersChanged(event.flags)
            return true
        default:
            return true
        }
    }

    private func mouseDown(at point: CGPoint) {
        dragGeneration &+= 1
        if drag?.owns == true { placer.endDrag() } // the last drag never saw its mouse-up
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
                  let op = SnapEngine.Operation.detect(from: d.startFrame, to: now, grabbedAt: d.startMouse) else { drag = d; return true }
            // A window resized by hand keeps its new size: dragging it out of its zone later
            // leaves it alone.
            if op != .move { zones?.forget(d.windowID) }
            // Without snapping only moves matter (for zones), and macOS keeps doing the dragging.
            guard snapping || (op == .move && zones != nil) else { drag = nil; return true }
            // Only take over windows we can actually place; otherwise leave the drag to macOS.
            guard let window = service.window(withID: d.windowID, pid: d.pid),
                  op == .move ? window.isMovable : window.isResizable else { drag = nil; return true }
            d.window = window
            d.owns = snapping
            d.snaps = snapping
            if op == .move {
                zones?.beginDrag()
                // A window dragged out of a zone gets its old size back, keeping the point under
                // the cursor at the same relative spot across the title bar. This controller then
                // moves the window for the rest of the drag even with snapping off, since macOS's
                // own drag would not follow the new size.
                if let size = zones?.takeRestoreSize(d.windowID, pid: d.pid, current: d.startFrame) {
                    d.startFrame = Self.restoredFrame(d.startFrame, size: size, mouse: d.startMouse)
                    d.resize = true
                    d.owns = true
                }
            }
            let others = WindowList.onScreen().filter { $0.windowID != d.windowID }.map(\.frame)
            let screens = DisplayService.displays.map(\.visibleFrame)
            d.session = SnapSession(engine: engine, operation: op, others: others, screens: screens)
            placer.refreshRate = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
            DragTrace.begin(app: NSRunningApplication(processIdentifier: d.pid)?.localizedName ?? "pid \(d.pid)",
                            windowID: d.windowID, operation: "\(op)", owns: d.owns)
        }
        guard var session = d.session, let window = d.window else { drag = d; return true }

        // From here on this controller is the only thing moving the window, like a Linux window
        // manager: every drag event is swallowed and the window is placed at the mouse-derived frame,
        // snapped. There is no hand-over between macOS and the snapper, so nothing jumps.
        let raw = Self.rawFrame(start: d.startFrame, operation: session.operation,
                                dx: mouse.x - d.startMouse.x, dy: mouse.y - d.startMouse.y)
        let inZones = session.operation == .move && zones?.update(mouse: mouse, flags: flags) != nil
        guard d.owns else { drag = d; return true }
        // Over zones, or while the bypass key is held, the window just follows the mouse; it goes
        // into the zone on release.
        let target = inZones || !snaps(d, flags) ? raw : session.update(raw)
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
        defer { drag = nil; DragTrace.end() }
        guard let d = drag, var session = d.session, let window = d.window else { return }
        if session.operation == .move, let zone = zones?.endDrag(mouse: mouse, flags: flags) {
            if d.owns {
                placer.place(window, frame: zone)
            } else {
                // macOS is still ending its own drag; place the window once it has let go.
                let placer = placer
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    placer.place(window, frame: zone)
                    placer.endDrag()
                }
            }
            zones?.didZone(d.windowID, pid: d.pid, original: d.startFrame.size, placed: zone)
            if d.owns { placer.endDrag() }
            return
        }
        guard d.owns else { return }
        defer { placer.endDrag() }
        let raw = Self.rawFrame(start: d.startFrame, operation: session.operation,
                                dx: mouse.x - d.startMouse.x, dy: mouse.y - d.startMouse.y)
        let target = snaps(d, flags) ? session.update(raw) : raw
        if target != d.placed { place(window, at: target, operation: session.operation) }
        holdAfterRelease(window, at: target, operation: session.operation)
    }

    /// Keeps a released window where the drag left it. The mouse-up is passed on so the app and
    /// macOS end their drag, and some apps (or macOS, finishing a title-bar drag it started before
    /// this controller took over) then move the window to where *they* think it belongs: the
    /// unsnapped spot under the cursor. That showed up as a window jumping back off the edge it had
    /// snapped to. For a short while after release, anything that moves the window away from the
    /// final frame is undone, unless a new drag has started.
    private func holdAfterRelease(_ window: Window, at target: CGRect, operation: SnapEngine.Operation) {
        // Moves only: after a resize an app may legitimately adjust the size (terminals round to
        // whole character cells), and that must not be fought.
        guard operation == .move, let wid = window.windowID else { return }
        let generation = dragGeneration
        var corrections = 0
        for delay in [0.05, 0.12, 0.25, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.dragGeneration == generation, self.drag == nil,
                      let now = WindowList.frame(of: wid),
                      !WindowPlacer.arrived(now, at: target, operation: operation) else { return }
                corrections += 1
                Self.releaseLog.notice("wid \(wid) moved after release to \(now.debugDescription, privacy: .public), restoring \(target.debugDescription, privacy: .public) (\(corrections))")
                self.placer.place(window, at: target, operation: operation)
                self.placer.endDrag()
            }
        }
    }

    /// Snap edges on this event: snapping is on for the drag and the bypass key is not held.
    private func snaps(_ d: DragState, _ flags: CGEventFlags) -> Bool {
        guard d.snaps else { return false }
        guard let key = bypassKey else { return true }
        return !flags.contains(key.flag)
    }

    /// A modifier went down or up mid-drag: updates the zones, and places the window again where
    /// the mouse is now, snapped or not, so the bypass key frees or re-snaps it at once.
    private func modifiersChanged(_ flags: CGEventFlags) {
        guard var d = drag, var session = d.session, let window = d.window else { return }
        let inZones = session.operation == .move && zones?.update(mouse: d.mouse, flags: flags) != nil
        guard d.owns, !inZones, !d.resize else { return }
        let raw = Self.rawFrame(start: d.startFrame, operation: session.operation,
                                dx: d.mouse.x - d.startMouse.x, dy: d.mouse.y - d.startMouse.y)
        let target = snaps(d, flags) ? session.update(raw) : raw
        d.session = session
        if target != d.placed { place(window, at: target, operation: session.operation) }
        d.placed = target
        drag = d
    }

    /// The frame a window dragged out of its zone gets: its old size, at the same top edge, with the
    /// point under the cursor at the same relative spot across the title bar (FancyZones does the
    /// same), and the cursor always over the window even when the old size is narrow.
    nonisolated static func restoredFrame(_ zoned: CGRect, size: CGSize, mouse: CGPoint) -> CGRect {
        let fraction = min(max((mouse.x - zoned.minX) / max(zoned.width, 1), 0), 1)
        let x = mouse.x - fraction * size.width
        return CGRect(x: x, y: zoned.minY, width: size.width, height: size.height)
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
///
/// Two things keep a drag smooth in every app:
/// - Apps with `AXEnhancedUserInterface` on (Firefox, and Chromium/Electron apps, once an assistive
///   tool has switched it on) animate every Accessibility move or resize. Each new position then
///   restarts a short slide, and the window trails the cursor by 30 to 250 px. The placer turns
///   the flag off for the length of the drag (see `endDrag`) and puts it back afterwards, as
///   `WindowService.setFrame` does for a single placement.
/// - Placements are capped at the refresh rate of the fastest display (a 1000 Hz mouse sends about
///   1,100 drag events a second), and after each one the placer waits, up to two frames, until the
///   window server shows the window at the new frame, so an app that moves its window late is
///   never handed a queue of positions.
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

    /// The shortest time between two placements: one frame of the fastest display.
    private var minInterval: CFTimeInterval = 1.0 / 60
    /// Apps whose `AXEnhancedUserInterface` this placer switched off. Only used on `queue`.
    private var enhancedOff: [pid_t: AXUIElement] = [:]
    /// Apps already checked for it during this drag. Only used on `queue`.
    private var checked: Set<pid_t> = []

    /// Of the fastest display, in Hz. Set at the start of each drag (displays come and go).
    var refreshRate: Int {
        get { lock.withLock { Int((1 / minInterval).rounded()) } }
        set { lock.withLock { minInterval = 1 / Double(min(max(newValue, 30), 240)) } }
    }

    func place(_ window: Window, frame: CGRect) {
        enqueue(Request(window: window, frame: frame, operation: nil))
    }

    func place(_ window: Window, at frame: CGRect, operation: SnapEngine.Operation) {
        enqueue(Request(window: window, frame: frame, operation: operation))
    }

    /// Call once the drag's last placement has been requested: after it lands, apps get their
    /// `AXEnhancedUserInterface` back.
    func endDrag() {
        queue.async { self.restoreEnhancedUI() }
    }

    private func enqueue(_ request: Request) {
        lock.lock()
        if pending != nil { DragTrace.coalesced() }
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
        var last: CFAbsoluteTime = 0
        while true {
            let interval = lock.withLock { minInterval }
            let wait = last + interval - CFAbsoluteTimeGetCurrent()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            lock.lock()
            guard let r = pending else { draining = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            last = CFAbsoluteTimeGetCurrent()
            disableEnhancedUI(r.window.pid)
            let before = r.window.windowID.flatMap(WindowList.frame(of:))
            apply(r)
            let arrived = settle(r, from: before)
            if DragTrace.enabled {
                let actual = r.window.windowID.flatMap(WindowList.frame(of:))
                DragTrace.placed(ms: (CFAbsoluteTimeGetCurrent() - last) * 1000, arrived: arrived, target: r.frame, actual: actual)
            }
        }
    }

    private func disableEnhancedUI(_ pid: pid_t) {
        guard checked.insert(pid).inserted else { return }
        let app = AX.application(pid)
        let on: Bool = AX.attribute(app, "AXEnhancedUserInterface") ?? false
        guard on else { return }
        AX.set(app, "AXEnhancedUserInterface", kCFBooleanFalse)
        enhancedOff[pid] = app
    }

    private func restoreEnhancedUI() {
        for app in enhancedOff.values { AX.set(app, "AXEnhancedUserInterface", kCFBooleanTrue) }
        enhancedOff = [:]
        checked = []
    }

    /// Waits until the window server has the window at the requested frame, or somewhere new and
    /// holding still (the app or macOS clamped it, e.g. under the menu bar), for up to two frames.
    /// Returns false on a timeout.
    @discardableResult
    private func settle(_ r: Request, from before: CGRect?) -> Bool {
        guard let wid = r.window.windowID else { return true }
        let deadline = CFAbsoluteTimeGetCurrent() + 2 * lock.withLock { minInterval }
        var previous: CGRect?
        while CFAbsoluteTimeGetCurrent() < deadline {
            guard let f = WindowList.frame(of: wid) else { return true }
            if Self.arrived(f, at: r.frame, operation: r.operation) { return true }
            if f != before, f == previous { return true }
            previous = f
            Thread.sleep(forTimeInterval: 0.001)
        }
        return false
    }

    nonisolated static func arrived(_ actual: CGRect, at target: CGRect, operation: SnapEngine.Operation?) -> Bool {
        let originOK = abs(actual.minX - target.minX) <= 1 && abs(actual.minY - target.minY) <= 1
        let sizeOK = abs(actual.width - target.width) <= 1 && abs(actual.height - target.height) <= 1
        switch operation {
        case .move?: return originOK
        case .resize(let e)?: return sizeOK && (originOK || !(e.contains(.left) || e.contains(.top)))
        case nil: return originOK && sizeOK
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

/// Timing for one drag, logged when the `traceDrag` default is on:
/// `defaults write io.marky.windowmanager traceDrag -bool YES`, then
/// `log stream --predicate 'subsystem == "io.marky.windowmanager"' --level info`.
enum DragTrace {
    static let enabled = UserDefaults.standard.bool(forKey: "traceDrag")
    private static let log = Logger(subsystem: "io.marky.windowmanager", category: "drag")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var s = Stats()

    private struct Stats {
        var label = ""
        var start = CFAbsoluteTimeGetCurrent()
        var active = false
        var events = 0, slowEvents = 0, placed = 0, coalesced = 0, timeouts = 0
        var timeline: [String] = []
        var tapMs: [Double] = [], ageMs: [Double] = [], axMs: [Double] = []
    }

    static func begin(app: String, windowID: CGWindowID, operation: String, owns: Bool) {
        guard enabled else { return }
        lock.withLock { s = Stats(label: "\(app) wid \(windowID) \(operation) owns=\(owns)", active: true) }
    }

    static func tap(_ type: CGEventType, ms: Double, ageMs: Double) {
        guard type == .leftMouseDragged else { return }
        lock.withLock {
            guard s.active else { return }
            s.events += 1
            s.tapMs.append(ms)
            s.ageMs.append(ageMs)
            if ms > 4 { s.slowEvents += 1 }
        }
    }

    static func coalesced() { guard enabled else { return }; lock.withLock { s.coalesced += 1 } }

    /// One placement: Accessibility call plus waiting for the window to get there.
    static func placed(ms: Double, arrived: Bool, target: CGRect, actual: CGRect?) {
        lock.withLock {
            guard s.active else { return }
            if s.timeline.count < 400 {
                let a = actual.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "?"
                s.timeline.append(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - s.start) + " target \(Int(target.minX)),\(Int(target.minY)) actual \(a)")
            }
            s.placed += 1
            s.axMs.append(ms)
            if !arrived { s.timeouts += 1 }
        }
    }

    static func end() {
        guard enabled else { return }
        let st: Stats = lock.withLock { let c = s; s.active = false; return c }
        guard st.active else { return }
        func p(_ a: [Double], _ q: Double) -> String {
            guard !a.isEmpty else { return "-" }
            let v = a.sorted()[min(a.count - 1, Int(Double(a.count) * q))]
            return String(format: "%.2f", v)
        }
        let secs = CFAbsoluteTimeGetCurrent() - st.start
        log.notice("""
        drag \(st.label, privacy: .public): \(String(format: "%.2f", secs), privacy: .public)s \
        events \(st.events) (\(st.slowEvents) over 4ms) tap ms p50 \(p(st.tapMs, 0.5), privacy: .public) p95 \(p(st.tapMs, 0.95), privacy: .public) max \(p(st.tapMs, 1), privacy: .public) \
        event age ms p50 \(p(st.ageMs, 0.5), privacy: .public) p95 \(p(st.ageMs, 0.95), privacy: .public) max \(p(st.ageMs, 1), privacy: .public) | \
        placed \(st.placed) (\(String(format: "%.0f", Double(st.placed) / max(secs, 0.001)), privacy: .public)/s) coalesced \(st.coalesced) place+settle ms p50 \(p(st.axMs, 0.5), privacy: .public) p95 \(p(st.axMs, 0.95), privacy: .public) max \(p(st.axMs, 1), privacy: .public) \
        settle timeouts \(st.timeouts)
        """)
        for line in st.timeline { log.info("  \(line, privacy: .public)") }
    }
}
