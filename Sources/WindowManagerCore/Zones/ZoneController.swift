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
    /// While Ctrl is held: the zones selected when it went down, the far corner of a span.
    private var anchor: (display: CGDirectDisplayID, zones: [Int])?
    private var showing = false

    /// Windows this controller resized into a zone: their size before, and the frame it gave them.
    private var zoned: [CGWindowID: (original: CGSize, placed: CGRect)] = [:]

    public init(store: ZoneStore, service: WindowService = WindowService()) {
        self.store = store
        self.service = service
    }

    // MARK: Dragging

    public func isActive(_ flags: CGEventFlags) -> Bool {
        guard store.enabled else { return false }
        let held = flags.contains(store.modifier.flag)
        return store.activation == .hold ? held : !held
    }

    /// Call when a window move starts.
    public func beginDrag() {
        dragZones = DisplayService.displays.map { ($0, store.zones(on: $0)) }
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
        let current = ZonePicker.zones(at: mouse, in: rects, spanAdjacent: store.spanAdjacentZones)
        var selected = current
        if flags.contains(store.modifier.spanModifier.flag) {
            if anchor?.display != display.id, !current.isEmpty { anchor = (display.id, current) }
            if let a = anchor { selected = ZonePicker.span(a.zones + current, in: rects) }
        } else {
            anchor = nil
            if selected.count > 1 { selected = ZonePicker.span(selected, in: rects) }
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

    /// Records that a window was put into a zone. `original` is kept if it was already zoned.
    public func didZone(_ wid: CGWindowID, original: CGSize, placed: CGRect) {
        zoned[wid] = (zoned[wid]?.original ?? original, placed)
    }

    /// The size a zoned window should get back when a drag takes it out of its zone, if the window
    /// is still the size its zone gave it. Forgets the window either way.
    public func takeRestoreSize(_ wid: CGWindowID, current: CGRect) -> CGSize? {
        guard let z = zoned.removeValue(forKey: wid), store.restoreSizeOnDragOut else { return nil }
        let same = abs(z.placed.width - current.width) < 4 && abs(z.placed.height - current.height) < 4
        return same ? z.original : nil
    }

    // MARK: Hotkeys

    /// Applies the n-th layout (0-based) to the display of the focused window, else the display
    /// under the mouse, and shows its zones for a moment.
    public func applyLayout(at index: Int) {
        guard store.layouts.indices.contains(index) else { NSSound.beep(); return }
        let displays = DisplayService.displays
        let target = service.focusedWindow()?.frame.flatMap { DisplayService.display(for: $0, in: displays) }
            ?? displays.first { $0.frame.contains(Self.mouseLocation) }
        guard let display = target else { return }
        store.assign(store.layouts[index].id, to: display)
        overlay.flash([(display, store.zones(on: display))])
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
        if let wid = window.windowID { didZone(wid, original: frame.size, placed: rect) }
    }

    /// Cursor position in AX space.
    static var mouseLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
