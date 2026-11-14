import CoreGraphics
import XCTest
@testable import WindowManagerCore

final class WindowPlacerTests: XCTestCase {
    private let target = CGRect(x: 100, y: 200, width: 800, height: 600)

    func testMoveArrivesOnOriginAlone() {
        XCTAssertTrue(WindowPlacer.arrived(CGRect(x: 101, y: 199, width: 640, height: 480), at: target, operation: .move))
        XCTAssertFalse(WindowPlacer.arrived(target.offsetBy(dx: 30, dy: 0), at: target, operation: .move))
    }

    func testRightEdgeResizeIgnoresOrigin() {
        let actual = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertTrue(WindowPlacer.arrived(actual, at: target, operation: .resize([.right])))
        XCTAssertFalse(WindowPlacer.arrived(actual, at: target, operation: .resize([.left])))
    }

    func testFullPlacementNeedsOriginAndSize() {
        XCTAssertTrue(WindowPlacer.arrived(target, at: target, operation: nil))
        XCTAssertFalse(WindowPlacer.arrived(CGRect(origin: target.origin, size: CGSize(width: 790, height: 600)),
                                            at: target, operation: nil))
    }
}
