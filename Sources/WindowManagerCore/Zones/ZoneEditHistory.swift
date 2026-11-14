import Foundation

/// Undo and redo for Settings › Zones: edits inside a layout, and changes to the list of layouts
/// (new, duplicate, delete, reorder, reset). One history, like a document's.
///
/// Every layout edit goes through `commit` / `edit`, which records the layout as it was before.
/// Edits that share a coalescing key become one undo step: a whole drag (one key per gesture),
/// or a run of arrow-key nudges / slider moves no more than `within` seconds apart. Undoing an
/// edit to a layout that isn't on screen first shows it (`show`), so nothing changes out of sight.
@MainActor
public final class ZoneEditHistory {
    private let store: ZoneStore
    private let now: () -> Date
    /// The last recorded edit, for coalescing. Cleared by undo, redo and list changes.
    private var last: (layout: UUID, key: String, name: String, time: Date)?

    public let undoManager = UndoManager()
    /// Whether Settings › Zones is on screen. ⌘Z and the Edit menu act on zones only then.
    public var isEditorVisible = false
    /// Shows a layout in the editor (assigns it to the display being edited). Called before
    /// undoing or redoing an edit to it.
    public var show: ((UUID) -> Void)?

    public init(store: ZoneStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// The undo manager for the Settings window while the zone editor is on screen.
    public var activeManager: UndoManager? { isEditorVisible ? undoManager : nil }

    /// Whether new undo groups follow run loop events (the app); tests turn it off and get one
    /// group per change.
    public var groupsByEvent: Bool {
        get { undoManager.groupsByEvent }
        set { undoManager.groupsByEvent = newValue }
    }

    // MARK: Layout edits

    /// Saves `layout` (one already in the store, matched by id) as an undoable edit named `name`.
    /// With a `coalesce` key equal to the previous edit's, no new undo step is made, so undo
    /// goes back to before the first of them. `within` limits that to edits at most that many
    /// seconds after the one before (nil: no limit, for keys that end with a gesture).
    public func commit(_ layout: ZoneLayout, _ name: String, coalesce key: String? = nil, within: TimeInterval? = nil) {
        guard let old = store.layout(id: layout.id), old != layout else { return }
        let t = now()
        let um = undoManager
        let joins: Bool = {
            guard let key, let last, last.layout == layout.id, last.key == key, last.name == name,
                  um.canUndo, um.undoActionName == name else { return false }
            if let within { return t.timeIntervalSince(last.time) <= within }
            return true
        }()
        if !joins { registerLayout(old, name) }
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

    // MARK: Layout list

    /// Adds a layout (new or duplicated) and shows it on `display` (a ZoneStore assignment key).
    @discardableResult
    public func addLayout(_ layout: ZoneLayout, showOn displayKey: String?, _ name: String = "New Layout") -> ZoneLayout {
        changeList(name) {
            store.add(layout)
            if let displayKey { store.assignments[displayKey] = layout.id }
        }
        return layout
    }

    /// Deletes a layout (not the last one). Undo brings it back where it was, and on the
    /// displays that used it.
    public func deleteLayout(_ id: UUID) {
        guard store.layouts.count > 1, store.layout(id: id) != nil else { return }
        changeList("Delete Layout") { store.delete(id) }
    }

    /// Puts the layouts in `order` (their ids, each exactly once) as one undo step. A display
    /// that has no layout of its own uses the first one, so each of `displayKeys` (ZoneStore
    /// assignment keys) without one is first given the layout it uses now: moving layouts
    /// around never changes the zones on a display.
    public func reorderLayouts(_ order: [UUID], keeping displayKeys: [String] = []) {
        guard order.count == store.layouts.count, Set(order) == Set(store.layouts.map(\.id)),
              order != store.layouts.map(\.id) else { return }
        changeList("Move Layout") {
            if let first = store.layouts.first?.id {
                for key in displayKeys where store.assignments[key].flatMap(store.layout(id:)) == nil {
                    store.assignments[key] = first
                }
            }
            store.reorder(order)
        }
    }

    /// Replaces every layout with the defaults.
    public func resetLayouts() {
        changeList("Reset Layouts") { store.resetLayouts() }
    }

    // MARK: Recording

    private struct ListState {
        var layouts: [ZoneLayout]
        var assignments: [String: UUID]
    }

    private func changeList(_ name: String, _ change: () -> Void) {
        let before = ListState(layouts: store.layouts, assignments: store.assignments)
        change()
        registerList(before, name)
        last = nil
    }

    private func group(_ body: () -> Void) {
        let um = undoManager
        let manual = !um.groupsByEvent && !um.isUndoing && !um.isRedoing
        if manual { um.beginUndoGrouping() }
        body()
        if manual { um.endUndoGrouping() }
    }

    private func registerLayout(_ snapshot: ZoneLayout, _ name: String) {
        group {
            undoManager.registerUndo(withTarget: self) { history in
                MainActor.assumeIsolated { history.restoreLayout(snapshot, name) }
            }
            undoManager.setActionName(name)
        }
    }

    private func registerList(_ snapshot: ListState, _ name: String) {
        group {
            undoManager.registerUndo(withTarget: self) { history in
                MainActor.assumeIsolated { history.restoreList(snapshot, name) }
            }
            undoManager.setActionName(name)
        }
    }

    /// Undo / redo of a layout edit: puts `snapshot` back (showing that layout first) and records
    /// the current state for the opposite direction.
    private func restoreLayout(_ snapshot: ZoneLayout, _ name: String) {
        last = nil
        guard let current = store.layout(id: snapshot.id) else { return }
        registerLayout(current, name)
        show?(snapshot.id)
        store.update(snapshot)
    }

    private func restoreList(_ snapshot: ListState, _ name: String) {
        last = nil
        registerList(ListState(layouts: store.layouts, assignments: store.assignments), name)
        store.layouts = snapshot.layouts
        store.assignments = snapshot.assignments
    }
}
