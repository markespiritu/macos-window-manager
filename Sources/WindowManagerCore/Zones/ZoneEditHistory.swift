import Foundation

/// Undo and redo for the zone layout editor: one `UndoManager` per layout, so undoing never
/// changes a layout other than the one on screen.
///
/// Every edit goes through `commit`, which records the layout as it was before. Edits that
/// share a coalescing key become one undo step: a whole drag (one key per gesture), or a run
/// of arrow-key nudges / slider moves no more than `within` seconds apart.
@MainActor
public final class ZoneEditHistory {
    private let store: ZoneStore
    private let now: () -> Date
    private var managers: [UUID: UndoManager] = [:]
    /// The last recorded edit, for coalescing. Cleared by undo and redo.
    private var last: (layout: UUID, key: String, name: String, time: Date)?

    /// The layout the editor shows, if the editor is on screen. ⌘Z and the Edit menu act on it.
    public var activeLayout: UUID?
    /// Whether new undo managers group by run loop event (the app); tests turn it off and get
    /// one group per edit.
    public var groupsByEvent = true

    public init(store: ZoneStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// The undo manager of the layout on screen.
    public var activeManager: UndoManager? { activeLayout.map(manager(for:)) }

    public func manager(for id: UUID) -> UndoManager {
        if let m = managers[id] { return m }
        let m = UndoManager()
        m.groupsByEvent = groupsByEvent
        managers[id] = m
        return m
    }

    /// Saves `layout` (one already in the store, matched by id) as an undoable edit named `name`.
    /// With a `coalesce` key equal to the previous edit's, no new undo step is made, so undo
    /// goes back to before the first of them. `within` limits that to edits at most that many
    /// seconds after the one before (nil: no limit, for keys that end with a gesture).
    public func commit(_ layout: ZoneLayout, _ name: String, coalesce key: String? = nil, within: TimeInterval? = nil) {
        guard let old = store.layout(id: layout.id), old != layout else { return }
        let t = now()
        let um = manager(for: layout.id)
        let joins: Bool = {
            guard let key, let last, last.layout == layout.id, last.key == key, last.name == name,
                  um.canUndo, um.undoActionName == name else { return false }
            if let within { return t.timeIntervalSince(last.time) <= within }
            return true
        }()
        if !joins { register(old, name, in: um) }
        last = key.map { (layout.id, $0, name, t) }
        store.update(layout)
    }

    /// `commit` for an edit made in place.
    public func edit(_ id: UUID, _ name: String, coalesce key: String? = nil, within: TimeInterval? = nil,
                     _ change: (inout ZoneLayout) -> Void) {
        guard var l = store.layout(id: id) else { return }
        change(&l)
        commit(l, name, coalesce: key, within: within)
    }

    /// Drops a layout's history (it was deleted).
    public func forget(_ id: UUID) {
        managers[id]?.removeAllActions()
        managers[id] = nil
        if last?.layout == id { last = nil }
    }

    /// Drops every layout's history (the layouts were reset).
    public func forgetAll() {
        managers.values.forEach { $0.removeAllActions() }
        managers = [:]
        last = nil
    }

    private func register(_ snapshot: ZoneLayout, _ name: String, in um: UndoManager) {
        let group = !um.groupsByEvent && !um.isUndoing && !um.isRedoing
        if group { um.beginUndoGrouping() }
        defer { if group { um.endUndoGrouping() } }
        um.registerUndo(withTarget: self) { [weak um] history in
            guard let um else { return }
            MainActor.assumeIsolated { history.restore(snapshot, name, in: um) }
        }
        um.setActionName(name)
    }

    /// Undo / redo: puts `snapshot` back and records the current state for the opposite direction.
    private func restore(_ snapshot: ZoneLayout, _ name: String, in um: UndoManager) {
        last = nil
        guard let current = store.layout(id: snapshot.id) else { return }
        register(current, name, in: um)
        store.update(snapshot)
    }
}
