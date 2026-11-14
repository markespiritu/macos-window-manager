import AppKit

/// Puts windows into zones: while a window is dragged (driven by `SnapController`) and from
/// hotkeys. Shows the overlay and remembers which windows it resized so they can get their
/// size back when dragged out again.
@MainActor
public final class ZoneController {
    public let store: ZoneStore
    private let overlay = ZoneOverlay()
    private let service: WindowService

    /// Zones of every display, captured when a drag starts.
    private var dragZones: [(display: Display, rects: [CGRect])] = []
    private var dragLayers: [CGDirectDisplayID: [Int]] = [:]
    /// While Ctrl is held: the zones selected when it went down, the far corner of a span.
    private var anchor: (display: CGDirectDisplayID, zones: [Int])?
    private var showing = false

    /// Windows this controller resized into a zone: their size before, and the frame it gave them.
    /// Kept in UserDefaults, so a window zoned before the app was relaunched still gets its size back.
    private var zoned: ZonedWindows

    public init(store: ZoneStore, service: WindowService = WindowService(), defaults: UserDefaults = .standard) {
        self.store = store
        self.service = service
        zoned = ZonedWindows(defaults: defaults)
    }

    // MARK: Dragging

    public func isActive(_ flags: CGEventFlags) -> Bool {
        guard store.enabled else { return false }
        let held = flags.contains(store.modifier.flag)
        return store.activation == .hold ? held : !held
    }

    /// Call when a window move starts.
    public func beginDrag() {
        let displays = DisplayService.displays
        dragZones = displays.map { ($0, store.zones(on: $0)) }
        dragLayers = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, store.zoneLayers(on: $0)) })
        anchor = nil
    }

    /// Updates the overlay for the cursor and returns the frame the window would get if dropped
    /// now, or nil when zones are not active (the window then snaps as usual).
    @discardableResult
    public func update(mouse: CGPoint, flags: CGEventFlags) -> CGRect? {
        guard isActive(flags), !dragZones.isEmpty else { hideOverlay(); anchor = nil; return nil }
        guard let di = dragZones.firstIndex(where: { $0.display.frame.contains(mouse) }) else {
            show(active: nil, selected: [])
            return nil
        }
        let (display, rects) = dragZones[di]
        let layers = dragLayers[display.id]
        let current = ZonePicker.zones(at: mouse, in: rects, layers: layers, rule: store.overlapRule,
                                       spanAdjacent: store.spanAdjacentZones)
        var selected = current
        if flags.contains(store.modifier.spanModifier.flag) {
            if anchor?.display != display.id, !current.isEmpty { anchor = (display.id, current) }
            if let a = anchor {
                // Only zones of the anchor's kind (split or free) join the span.
                selected = ZonePicker.span(a.zones + current, in: rects, layers: layers)
            }
        } else {
            anchor = nil
            if selected.count > 1 { selected = ZonePicker.span(selected, in: rects, layers: layers) }
        }
        show(active: display.id, selected: Set(selected))
        return ZonePicker.bounds(selected, in: rects)
    }

    /// Call when the mouse is released. Returns the zone frame to drop the window into, if any.
    public func endDrag(mouse: CGPoint, flags: CGEventFlags) -> CGRect? {
        let target = update(mouse: mouse, flags: flags)
        cancelDrag()
        return target
    }

    public func cancelDrag() {
        hideOverlay()
        dragZones = []
        dragLayers = [:]
        anchor = nil
    }

    private func show(active: CGDirectDisplayID?, selected: Set<Int>) {
        overlay.show(dragZones, active: active, selected: selected)
        showing = true
    }

    private func hideOverlay() {
        guard showing else { return }
        overlay.hide()
        showing = false
    }

    // MARK: Remembered sizes

    /// Records that a window was put into a zone. `original` is kept if it was already zoned, so
    /// moving a window from zone to zone still gives it its first size back.
    ///
    /// Apps do not always take the exact zone frame (Terminal sizes in whole character cells, some
    /// windows have a minimum size), so once the placement has landed the frame the window really
    /// got is remembered instead.
    public func didZone(_ wid: CGWindowID, pid: pid_t, original: CGSize, placed: CGRect) {
        zoned.set(wid, ZonedWindow(pid: pid, original: zoned.get(wid, pid: pid)?.original ?? original, placed: placed))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, var z = self.zoned.get(wid, pid: pid), z.placed == placed,
                  let actual = WindowList.frame(of: wid) else { return }
            z.placed = actual
            self.zoned.set(wid, z)
        }
    }

    /// The window was resized by hand: it keeps its new size from now on.
    public func forget(_ wid: CGWindowID) {
        zoned.remove(wid)
    }

    /// The size a zoned window should get back when a drag takes it out of its zone, if the window
    /// is still the size its zone gave it (not maximised or resized since). Forgets the window
    /// either way.
    public func takeRestoreSize(_ wid: CGWindowID, pid: pid_t, current: CGRect) -> CGSize? {
        guard let z = zoned.get(wid, pid: pid) else { return nil }
        zoned.remove(wid)
        guard store.restoreSizeOnDragOut, Self.sameSize(z.placed, current) else { return nil }
        return z.original
    }

    /// The window is still the size its zone gave it, allowing for a few points of rounding.
    nonisolated static func sameSize(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.width - b.width) <= 8 && abs(a.height - b.height) <= 8
    }

    // MARK: Hotkeys

    /// Uses a layout on a display (from the menu bar) and shows its zones for a moment.
    public func apply(_ layoutID: UUID, to display: Display) {
        store.assign(layoutID, to: display)
        overlay.flash([(display, store.zones(on: display))], seconds: 0.8)
    }

    /// Moves the focused window to the next (`step` 1) or previous (-1) zone, in zone order, on
    /// to the next display after the last zone.
    public func moveFocusedWindow(by step: Int) {
        guard store.enabled, let window = service.focusedWindow(), let frame = window.frame else { return }
        let displays = DisplayService.displays.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        let all = displays.flatMap { store.zones(on: $0) }
        guard !all.isEmpty else { return }
        let target: Int
        if let current = ZonePicker.zone(containing: frame, in: all) {
            target = (current + step + all.count) % all.count
        } else {
            // Not in a zone yet: start from the zones of the display it is on.
            let display = DisplayService.display(for: frame, in: displays)
            let offset = displays.prefix { $0.id != display?.id }.reduce(0) { $0 + store.zones(on: $1).count }
            let count = display.map { store.zones(on: $0).count } ?? all.count
            target = step > 0 ? offset : offset + max(count - 1, 0)
        }
        let rect = all[min(target, all.count - 1)]
        service.setFrame(rect, of: window)
        if let wid = window.windowID { didZone(wid, pid: window.pid, original: frame.size, placed: rect) }
    }

    /// Cursor position in AX space.
    static var mouseLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}

/// One window put into a zone.
struct ZonedWindow: Codable, Equatable {
    /// Window numbers are reused after a logout, so the owning process must match too.
    var pid: pid_t
    var original: CGSize
    var placed: CGRect
}

/// The zoned windows, persisted in UserDefaults under `zonedWindows`. Windows that no longer exist
/// are dropped when it loads.
struct ZonedWindows {
    private static let key = "zonedWindows"
    private let defaults: UserDefaults
    private var windows: [CGWindowID: ZonedWindow]

    init(defaults: UserDefaults, exists: (CGWindowID, pid_t) -> Bool = ZonedWindows.windowExists) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([CGWindowID: ZonedWindow].self, from: $0) } ?? [:]
        windows = saved.filter { exists($0.key, $0.value.pid) }
        if windows.count != saved.count { save() }
    }

    func get(_ wid: CGWindowID, pid: pid_t) -> ZonedWindow? {
        windows[wid].flatMap { $0.pid == pid ? $0 : nil }
    }

    mutating func set(_ wid: CGWindowID, _ window: ZonedWindow) {
        windows[wid] = window
        save()
    }

    mutating func remove(_ wid: CGWindowID) {
        guard windows.removeValue(forKey: wid) != nil else { return }
        save()
    }

    private func save() {
        if windows.isEmpty { defaults.removeObject(forKey: Self.key); return }
        if let data = try? JSONEncoder().encode(windows) { defaults.set(data, forKey: Self.key) }
    }

    static func windowExists(_ wid: CGWindowID, pid: pid_t) -> Bool {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]])?.first
        else { return false }
        return info[kCGWindowOwnerPID as String] as? pid_t == pid
    }
}
