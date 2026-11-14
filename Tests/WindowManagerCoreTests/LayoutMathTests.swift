import CoreGraphics
import XCTest
@testable import WindowManagerCore

final class LayoutMathTests: XCTestCase {
    // A 1512x949 visible area starting below a 33pt menu bar, like a 14" MacBook Pro.
    let visible = CGRect(x: 0, y: 33, width: 1512, height: 949)
    let window = CGRect(x: 200, y: 200, width: 800, height: 600)

    func frame(_ a: WindowAction, gap: CGFloat = 0, in v: CGRect? = nil) -> CGRect? {
        LayoutMath.frame(for: a, visibleFrame: v ?? visible, current: window, gap: gap)
    }

    func testHalvesTileTheVisibleArea() {
        let l = frame(.leftHalf)!, r = frame(.rightHalf)!
        XCTAssertEqual(l, CGRect(x: 0, y: 33, width: 756, height: 949))
        XCTAssertEqual(r, CGRect(x: 756, y: 33, width: 756, height: 949))
        let t = frame(.topHalf)!, b = frame(.bottomHalf)!
        XCTAssertEqual(t.minY, 33)
        XCTAssertEqual(b.maxY, visible.maxY)
        XCTAssertLessThanOrEqual(t.maxY, b.minY)
    }

    func testOddSizesNeverOverlap() {
        let v = CGRect(x: 0, y: 25, width: 1513, height: 951)
        let l = frame(.leftHalf, in: v)!, r = frame(.rightHalf, in: v)!
        XCTAssertLessThanOrEqual(l.maxX, r.minX)
        XCTAssertEqual(r.maxX, v.maxX)
    }

    func testMaximizeFillsVisibleFrame() {
        XCTAssertEqual(frame(.maximize), visible)
    }

    func testGapInsetsEdgesAndSeparatesHalves() {
        let l = frame(.leftHalf, gap: 10)!, r = frame(.rightHalf, gap: 10)!
        XCTAssertEqual(l.minX, 10)
        XCTAssertEqual(l.minY, 43)
        XCTAssertEqual(r.maxX, visible.maxX - 10)
        XCTAssertEqual(r.minX - l.maxX, 10, accuracy: 1)
    }

    func testCenterKeepsSizeAndClampsToScreen() {
        let c = frame(.center)!
        XCTAssertEqual(c.size, window.size)
        XCTAssertEqual(c.midX, visible.midX, accuracy: 1)
        XCTAssertEqual(c.midY, visible.midY, accuracy: 1)
        let big = LayoutMath.frame(for: .center, visibleFrame: visible,
                                   current: CGRect(x: 0, y: 0, width: 4000, height: 3000))!
        XCTAssertEqual(big.size, visible.size)
    }

    func testSecondaryDisplayLeftOfPrimary() {
        // Displays to the left of the primary have negative x; math must not assume origin 0.
        let v = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        XCTAssertEqual(frame(.rightHalf, in: v), CGRect(x: -960, y: 0, width: 960, height: 1055))
    }

    func testRestoreHasNoComputedFrame() {
        XCTAssertNil(frame(.restore))
    }
}

final class CoordinateTests: XCTestCase {
    func testFlipIsItsOwnInverse() {
        let r = CGRect(x: 10, y: 20, width: 300, height: 200)
        XCTAssertEqual(ScreenCoordinates.flip(ScreenCoordinates.flip(r, primaryHeight: 982), primaryHeight: 982), r)
    }

    func testFlipAppKitVisibleFrameToAX() {
        // AppKit visible frame on a 982pt-high screen with a 33pt menu bar and no Dock.
        let appKit = CGRect(x: 0, y: 0, width: 1512, height: 949)
        XCTAssertEqual(ScreenCoordinates.flip(appKit, primaryHeight: 982), CGRect(x: 0, y: 33, width: 1512, height: 949))
    }

    func testDisplayForRectPicksLargestOverlap() {
        let a = Display(id: 1, name: "A", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                        visibleFrame: .zero, isMain: true)
        let b = Display(id: 2, name: "B", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
                        visibleFrame: .zero, isMain: false)
        let mostlyOnB = CGRect(x: 900, y: 100, width: 400, height: 300)
        XCTAssertEqual(DisplayService.display(for: mostlyOnB, in: [a, b])?.id, 2)
        let offscreen = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        XCTAssertEqual(DisplayService.display(for: offscreen, in: [a, b])?.id, 1)
    }
}
