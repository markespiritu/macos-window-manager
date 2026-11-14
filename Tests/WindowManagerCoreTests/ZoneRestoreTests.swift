import CoreGraphics
import XCTest
@testable import WindowManagerCore

@MainActor
final class ZoneRestoreTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "ZoneRestoreTests-\(UUID())")! }
    private let zone = CGRect(x: 0, y: 25, width: 600, height: 800)

    private func controller(_ d: UserDefaults) -> ZoneController {
        ZoneController(store: ZoneStore(defaults: d), defaults: d)
    }

    func testRestoresOriginalSize() {
        let c = controller(defaults())
        c.didZone(7, pid: 1, original: CGSize(width: 900, height: 500), placed: zone)
        XCTAssertEqual(c.takeRestoreSize(7, pid: 1, current: zone), CGSize(width: 900, height: 500))
        XCTAssertNil(c.takeRestoreSize(7, pid: 1, current: zone), "forgotten after the drag out")
    }

    func testZoneToZoneKeepsFirstSize() {
        let c = controller(defaults())
        c.didZone(7, pid: 1, original: CGSize(width: 900, height: 500), placed: zone)
        let other = zone.offsetBy(dx: 600, dy: 0)
        c.didZone(7, pid: 1, original: zone.size, placed: other)
        XCTAssertEqual(c.takeRestoreSize(7, pid: 1, current: other), CGSize(width: 900, height: 500))
    }

    func testSmallRoundingStillRestores() {
        // Terminal sizes in whole character cells, so it ends a few points off the zone.
        let c = controller(defaults())
        c.didZone(7, pid: 1, original: CGSize(width: 900, height: 500), placed: zone)
        let actual = CGRect(x: 0, y: 25, width: 596, height: 794)
        XCTAssertEqual(c.takeRestoreSize(7, pid: 1, current: actual), CGSize(width: 900, height: 500))
    }

    func testResizedOrMaximisedWindowKeepsItsSize() {
        let c = controller(defaults())
        c.didZone(7, pid: 1, original: CGSize(width: 900, height: 500), placed: zone)
        XCTAssertNil(c.takeRestoreSize(7, pid: 1, current: CGRect(x: 0, y: 25, width: 1200, height: 800)))
        c.didZone(8, pid: 1, original: CGSize(width: 900, height: 500), placed: zone)
        c.forget(8)
        XCTAssertNil(c.takeRestoreSize(8, pid: 1, current: zone))
    }

    func testOtherProcessWithReusedWindowNumber() {
        let c = controller(defaults())
        c.didZone(7, pid: 1, original: CGSize(width: 900, height: 500), placed: zone)
        XCTAssertNil(c.takeRestoreSize(7, pid: 2, current: zone))
    }

    func testOffWhenSettingIsOff() {
        let d = defaults()
        let c = controller(d)
        c.store.restoreSizeOnDragOut = false
        c.didZone(7, pid: 1, original: CGSize(width: 900, height: 500), placed: zone)
        XCTAssertNil(c.takeRestoreSize(7, pid: 1, current: zone))
    }

    func testSurvivesRelaunchAndDropsClosedWindows() {
        let d = defaults()
        var z = ZonedWindows(defaults: d, exists: { _, _ in true })
        z.set(7, ZonedWindow(pid: 1, original: CGSize(width: 900, height: 500), placed: zone))
        z.set(8, ZonedWindow(pid: 1, original: CGSize(width: 300, height: 300), placed: zone))
        let reloaded = ZonedWindows(defaults: d, exists: { wid, _ in wid == 7 })
        XCTAssertEqual(reloaded.get(7, pid: 1)?.original, CGSize(width: 900, height: 500))
        XCTAssertNil(reloaded.get(8, pid: 1))
        XCTAssertNil(ZonedWindows(defaults: d, exists: { _, _ in true }).get(8, pid: 1), "pruned on disk too")
    }

    func testRestoredFrameKeepsCursorAtSameSpotAcrossTitleBar() {
        // Grabbed a quarter of the way across a 600 pt zone; the 1000 pt window is grabbed a quarter across too.
        let f = SnapController.restoredFrame(zone, size: CGSize(width: 1000, height: 500), mouse: CGPoint(x: 150, y: 35))
        XCTAssertEqual(f, CGRect(x: -100, y: 25, width: 1000, height: 500))
        let narrow = SnapController.restoredFrame(zone, size: CGSize(width: 200, height: 200), mouse: CGPoint(x: 590, y: 35))
        XCTAssertTrue(narrow.minX <= 590 && narrow.maxX >= 590)
    }
}
