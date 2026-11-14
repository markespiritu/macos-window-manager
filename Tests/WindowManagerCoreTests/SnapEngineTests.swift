import CoreGraphics
import XCTest
@testable import WindowManagerCore

final class SnapEngineTests: XCTestCase {
    let screen = CGRect(x: 0, y: 30, width: 2000, height: 1200)
    let engine = SnapEngine(distance: 15)
    let neighbour = CGRect(x: 1000, y: 200, width: 600, height: 700)

    func move(_ f: CGRect, others: [CGRect] = []) -> CGRect {
        engine.snap(f, operation: .move, others: others, screens: [screen])
    }

    func resize(_ f: CGRect, _ e: Edges, others: [CGRect] = []) -> CGRect {
        engine.snap(f, operation: .resize(e), others: others, screens: [screen])
    }

    // MARK: Screen edges

    func testSnapsToScreenEdgeWithinDistance() {
        XCTAssertEqual(move(CGRect(x: 10, y: 300, width: 500, height: 400)).minX, 0)
        XCTAssertEqual(move(CGRect(x: 1488, y: 300, width: 500, height: 400)).maxX, 2000)
        XCTAssertEqual(move(CGRect(x: 300, y: 40, width: 500, height: 400)).minY, 30) // below the menu bar
    }

    func testIgnoresScreenEdgeBeyondDistance() {
        let f = CGRect(x: 20, y: 300, width: 500, height: 400)
        XCTAssertEqual(move(f), f)
    }

    func testCornerSnapsBothAxes() {
        XCTAssertEqual(move(CGRect(x: 8, y: 38, width: 500, height: 400)).origin, CGPoint(x: 0, y: 30))
    }

    // MARK: Windows side by side

    func testSnapsFlushNextToWindow() {
        // Right edge 10pt short of the neighbour's left edge.
        let f = CGRect(x: 490, y: 400, width: 500, height: 300)
        XCTAssertEqual(move(f, others: [neighbour]).maxX, 1000)
        // Left edge 12pt past the neighbour's right edge (overlapping).
        let g = CGRect(x: 1588, y: 400, width: 300, height: 300)
        XCTAssertEqual(move(g, others: [neighbour]).minX, 1600)
    }

    func testDoesNotSnapToWindowItDoesNotFace() {
        // Well below the neighbour: their vertical ranges never face each other, so no x snap.
        let f = CGRect(x: 490, y: 1000, width: 500, height: 150)
        XCTAssertEqual(move(f, others: [neighbour]).minX, 490)
    }

    func testTopsAlignWhenSideBySide() {
        // Flush to the left of the neighbour, top 9pt lower: tops line up.
        let f = CGRect(x: 500, y: 209, width: 500, height: 300)
        let s = move(f, others: [neighbour])
        XCTAssertEqual(s.minY, 200)
        XCTAssertEqual(s.maxX, 1000)
    }

    func testCornerToCornerSnapsAndAligns() {
        // Near the neighbour's top-left corner from the left: both edges catch.
        let f = CGRect(x: 488, y: 192, width: 500, height: 300)
        XCTAssertEqual(move(f, others: [neighbour]).origin, CGPoint(x: 500, y: 200))
    }

    func testStackedWindowsAlignLeftEdges() {
        // Just below the neighbour with the left edge 7pt off: it sits flush below and lines up.
        let f = CGRect(x: 1007, y: 905, width: 400, height: 200)
        XCTAssertEqual(move(f, others: [neighbour]).origin, CGPoint(x: 1000, y: 900))
    }

    func testNearestTargetWins() {
        let other = CGRect(x: 1007, y: 200, width: 300, height: 700)
        let f = CGRect(x: 495, y: 400, width: 500, height: 300)
        XCTAssertEqual(move(f, others: [neighbour, other]).maxX, 1000)
    }

    // MARK: Resizing

    func testResizeBottomMatchesNeighbourHeight() {
        // Side by side, tops aligned, dragging the shorter window's bottom to 10pt above the
        // neighbour's bottom: it snaps to the same height. Only the bottom edge moves.
        let f = CGRect(x: 500, y: 200, width: 500, height: 690)
        XCTAssertEqual(resize(f, .bottom, others: [neighbour]), CGRect(x: 500, y: 200, width: 500, height: 700))
    }

    func testResizeRightEdgeSnapsFlush() {
        let f = CGRect(x: 500, y: 300, width: 488, height: 300)
        XCTAssertEqual(resize(f, .right, others: [neighbour]), CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    func testResizeLeftEdgeKeepsRightEdge() {
        let f = CGRect(x: 1612, y: 300, width: 300, height: 300)
        let s = resize(f, .left, others: [neighbour])
        XCTAssertEqual(s.minX, 1600)
        XCTAssertEqual(s.maxX, f.maxX)
    }

    func testResizeDoesNotMoveUndraggedEdges() {
        // Dragging only the bottom: the left edge is 8pt from the screen edge but must stay put.
        let f = CGRect(x: 8, y: 300, width: 400, height: 300)
        XCTAssertEqual(resize(f, .bottom).minX, 8)
    }

    // MARK: Options and detection

    func testOptionsDisableTargets() {
        let f = CGRect(x: 10, y: 400, width: 500, height: 300)
        XCTAssertEqual(SnapEngine(distance: 15, snapToScreen: false).snap(f, operation: .move, others: [], screens: [screen]), f)
        let g = CGRect(x: 490, y: 400, width: 500, height: 300)
        XCTAssertEqual(SnapEngine(distance: 15, snapToWindows: false).snap(g, operation: .move, others: [neighbour], screens: [screen]), g)
    }

    func testDetectOperation() {
        let a = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertNil(SnapEngine.Operation.detect(from: a, to: a))
        XCTAssertEqual(SnapEngine.Operation.detect(from: a, to: a.offsetBy(dx: 5, dy: 3)), .move)
        XCTAssertEqual(SnapEngine.Operation.detect(from: a, to: CGRect(x: 100, y: 100, width: 400, height: 350)), .resize(.bottom))
        XCTAssertEqual(SnapEngine.Operation.detect(from: a, to: CGRect(x: 80, y: 90, width: 420, height: 310)), .resize([.left, .top]))
    }
}

final class CoordinateTests: XCTestCase {
    func testFlipIsItsOwnInverse() {
        let r = CGRect(x: 10, y: 20, width: 300, height: 200)
        XCTAssertEqual(ScreenCoordinates.flip(ScreenCoordinates.flip(r, primaryHeight: 982), primaryHeight: 982), r)
    }

    func testFlipAppKitVisibleFrameToAX() {
        let appKit = CGRect(x: 0, y: 0, width: 1512, height: 949)
        XCTAssertEqual(ScreenCoordinates.flip(appKit, primaryHeight: 982), CGRect(x: 0, y: 33, width: 1512, height: 949))
    }

    func testDisplayForRectPicksLargestOverlap() {
        let a = Display(id: 1, name: "A", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: .zero, isMain: true)
        let b = Display(id: 2, name: "B", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), visibleFrame: .zero, isMain: false)
        XCTAssertEqual(DisplayService.display(for: CGRect(x: 900, y: 100, width: 400, height: 300), in: [a, b])?.id, 2)
        XCTAssertEqual(DisplayService.display(for: CGRect(x: 5000, y: 5000, width: 10, height: 10), in: [a, b])?.id, 1)
    }
}

@MainActor
final class SettingsTests: XCTestCase {
    func testSnappingSettingsPersist() {
        let d = UserDefaults(suiteName: "WindowManagerTests.\(UUID().uuidString)")!
        let s = SettingsStore(defaults: d)
        XCTAssertTrue(s.snappingEnabled)
        XCTAssertEqual(s.snapDistance, 15)
        s.snapDistance = 25
        s.snapToWindows = false
        let r = SettingsStore(defaults: d)
        XCTAssertEqual(r.snapEngine, SnapEngine(distance: 25, snapToScreen: true, snapToWindows: false))
    }
}
