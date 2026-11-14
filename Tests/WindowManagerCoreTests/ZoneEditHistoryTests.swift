import CoreGraphics
import XCTest
@testable import WindowManagerCore

@MainActor
final class ZoneEditHistoryTests: XCTestCase {
    private var store: ZoneStore!
    private var history: ZoneEditHistory!
    private var clock = Date(timeIntervalSince1970: 0)
    private var id: UUID { store.layouts[0].id }
    private var layout: ZoneLayout { store.layout(id: id)! }
    private var um: UndoManager { history.undoManager }

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "ZoneEditHistoryTests-\(UUID())")!
        store = ZoneStore(defaults: defaults)
        history = ZoneEditHistory(store: store, now: { [unowned self] in self.clock })
        history.groupsByEvent = false
    }

    private func addZone(at x: Double) {
        history.edit(id, "Add Zone") { $0.floating.append(FloatingZone(rect: CGRect(x: x, y: 0.1, width: 0.2, height: 0.2))) }
    }

    func testUndoRedoRestoresLayouts() {
        let original = layout
        addZone(at: 0.1)
        let one = layout
        addZone(at: 0.5)
        XCTAssertEqual(layout.floating.count, original.floating.count + 2)
        XCTAssertEqual(um.undoActionName, "Add Zone")

        um.undo()
        XCTAssertEqual(layout, one)
        um.undo()
        XCTAssertEqual(layout, original)
        XCTAssertFalse(um.canUndo)
        um.redo()
        XCTAssertEqual(layout, one)
        um.redo()
        XCTAssertEqual(layout.floating.count, original.floating.count + 2)
    }

    func testNoChangeRecordsNothing() {
        history.edit(id, "Nothing") { _ in }
        XCTAssertFalse(um.canUndo)
    }

    func testDragCoalescesIntoOneStep() {
        addZone(at: 0.1)
        let beforeDrag = layout
        let k = beforeDrag.floating.count - 1
        for step in 1...20 {
            clock += 5 // a slow drag still counts as one
            history.edit(id, "Move Zone", coalesce: "drag-1") { $0.floating[k].rect.origin.x = 0.1 + Double(step) / 100 }
        }
        um.undo()
        XCTAssertEqual(layout, beforeDrag)
        um.redo()
        XCTAssertEqual(layout.floating[k].rect.origin.x, 0.3, accuracy: 1e-9)

        // The next drag (new key) is a step of its own.
        history.edit(id, "Move Zone", coalesce: "drag-2") { $0.floating[k].rect.origin.x = 0.6 }
        um.undo()
        XCTAssertEqual(layout.floating[k].rect.origin.x, 0.3, accuracy: 1e-9)
    }

    func testNudgesCoalesceOnlyWhenClose() {
        addZone(at: 0.1)
        let start = layout
        let k = start.floating.count - 1
        func nudge() { history.edit(id, "Move Zone", coalesce: "nudge", within: 1) { $0.floating[k].rect.origin.x += 0.01 } }
        nudge(); clock += 0.5; nudge(); clock += 0.5; nudge()
        let afterBurst = layout
        clock += 3
        nudge()
        um.undo()
        XCTAssertEqual(layout, afterBurst)
        um.undo()
        XCTAssertEqual(layout, start)
    }

    func testUndoEndsCoalescing() {
        addZone(at: 0.1)
        let k = layout.floating.count - 1
        history.edit(id, "Move Zone", coalesce: "nudge", within: 1) { $0.floating[k].rect.origin.x = 0.2 }
        um.undo()
        let afterUndo = layout
        history.edit(id, "Move Zone", coalesce: "nudge", within: 1) { $0.floating[k].rect.origin.x = 0.3 }
        um.undo()
        XCTAssertEqual(layout, afterUndo)
    }

    func testUndoShowsTheEditedLayout() {
        var shown: [UUID] = []
        history.show = { shown.append($0) }
        addZone(at: 0.1)
        um.undo()
        XCTAssertEqual(shown, [id])
        history.isEditorVisible = false
        XCTAssertNil(history.activeManager)
        history.isEditorVisible = true
        XCTAssertTrue(history.activeManager === um)
    }

    func testDeleteLayoutUndoRestoresItAndItsDisplays() {
        let before = store.layouts
        let victim = before[1].id
        store.assignments["display-A"] = victim
        history.deleteLayout(victim)
        XCTAssertNil(store.layout(id: victim))
        XCTAssertNil(store.assignments["display-A"])
        XCTAssertEqual(um.undoActionName, "Delete Layout")
        um.undo()
        XCTAssertEqual(store.layouts, before)
        XCTAssertEqual(store.assignments["display-A"], victim)
        um.redo()
        XCTAssertNil(store.layout(id: victim))
    }

    func testAddAndResetLayoutsUndo() {
        let before = store.layouts
        let l = history.addLayout(ZoneTemplate.columns.layout(zones: 2), showOn: "display-A")
        XCTAssertEqual(store.assignments["display-A"], l.id)
        history.edit(l.id, "Add Zone") { $0.floating.append(FloatingZone(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))) }
        history.resetLayouts()
        XCTAssertNil(store.layout(id: l.id))
        um.undo() // reset
        XCTAssertEqual(store.layout(id: l.id)?.floating.count, 1)
        um.undo() // add zone
        um.undo() // new layout
        XCTAssertEqual(store.layouts, before)
        XCTAssertNil(store.assignments["display-A"])
    }

    func testDeletingTheLastLayoutDoesNothing() {
        while store.layouts.count > 1 { history.deleteLayout(store.layouts.last!.id) }
        let n = store.layouts.count
        history.deleteLayout(id)
        XCTAssertEqual(store.layouts.count, n)
    }
}
