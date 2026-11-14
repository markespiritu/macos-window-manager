import CoreGraphics
import XCTest
@testable import WindowManagerCore

final class ZoneLayoutTests: XCTestCase {
    let screen = CGRect(x: 0, y: 25, width: 1200, height: 800)

    func testColumnsWithSpacing() {
        let rects = ZoneTemplate.columns.root(zones: 3).zoneRects(in: screen, spacing: 10)
        XCTAssertEqual(rects.count, 3)
        XCTAssertEqual(rects[0].minX, 10)
        XCTAssertEqual(rects[2].maxX, 1190)
        XCTAssertEqual(rects[1].minX - rects[0].maxX, 10, accuracy: 1)
        XCTAssertEqual(rects[0].minY, 35)
        XCTAssertEqual(rects[0].height, 780)
    }

    func testGridAndPriorityGridCounts() {
        for n in 1...9 {
            XCTAssertEqual(ZoneTemplate.grid.root(zones: n).zoneCount, n, "grid \(n)")
            XCTAssertEqual(ZoneTemplate.priorityGrid.root(zones: n).zoneCount, n, "priority \(n)")
        }
        let p = ZoneTemplate.priorityGrid.root(zones: 3).zoneRects(in: screen)
        XCTAssertEqual(p[1].width, 600) // middle gets half
    }

    func testSplitSameAxisAddsSibling() {
        var root = ZoneTemplate.columns.root(zones: 2)
        root.split(zone: 1, along: .columns)
        XCTAssertEqual(root.children.count, 3)
        XCTAssertEqual(root.fractions, [0.5, 0.25, 0.25])
        root.split(zone: 0, along: .rows)
        XCTAssertEqual(root.zoneCount, 4)
        XCTAssertEqual(root.children[0].axis, .rows)
    }

    func testRemoveGivesSpaceToNeighbourAndCollapses() {
        var root = ZoneTemplate.columns.root(zones: 2)
        root.split(zone: 1, along: .rows) // [A | B/C]
        root.remove(zone: 2)               // [A | B]
        XCTAssertEqual(root.zoneCount, 2)
        XCTAssertEqual(root.axis, .columns)
        XCTAssertTrue(root.children.allSatisfy(\.isLeaf))
        root.remove(zone: 0)
        XCTAssertTrue(root.isLeaf)
        root.remove(zone: 0) // the last zone stays
        XCTAssertEqual(root.zoneCount, 1)
    }

    func testMoveDivider() {
        var root = ZoneTemplate.columns.root(zones: 2)
        let d = root.dividers(in: screen, spacing: 10)[0]
        root.move(d, to: 400, spacing: 10)
        let rects = root.zoneRects(in: screen, spacing: 10)
        XCTAssertEqual(rects[0].maxX, 395, accuracy: 1)
        XCTAssertEqual(rects[1].minX, 405, accuracy: 1)
        root.move(d, to: -1000, spacing: 10)
        XCTAssertEqual(root.fractions[0], 0.05, accuracy: 0.001) // clamped
    }

    func testCodableRoundTrip() throws {
        let layout = ZoneTemplate.priorityGrid.layout(zones: 5)
        let back = try JSONDecoder().decode(ZoneLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(back, layout)
    }
}

final class ZonePickerTests: XCTestCase {
    let rects = ZoneTemplate.grid.root(zones: 4).zoneRects(in: CGRect(x: 0, y: 0, width: 1000, height: 800), spacing: 10)

    func testInsideZone() {
        XCTAssertEqual(ZonePicker.zones(at: CGPoint(x: 200, y: 200), in: rects), [0])
        XCTAssertEqual(ZonePicker.zones(at: CGPoint(x: 800, y: 600), in: rects), [3])
    }

    func testBorderSpansBoth() {
        // In the gap between the two top zones.
        XCTAssertEqual(Set(ZonePicker.zones(at: CGPoint(x: 500, y: 200), in: rects)), [0, 1])
        XCTAssertEqual(ZonePicker.zones(at: CGPoint(x: 500, y: 200), in: rects, spanAdjacent: false).count, 1)
    }

    func testSpanFillsBox() {
        XCTAssertEqual(ZonePicker.span([0, 3], in: rects), [0, 1, 2, 3])
        XCTAssertEqual(ZonePicker.span([0, 1], in: rects), [0, 1])
    }

    func testZoneContaining() {
        XCTAssertEqual(ZonePicker.zone(containing: rects[2].insetBy(dx: 5, dy: 5), in: rects), 2)
        XCTAssertNil(ZonePicker.zone(containing: CGRect(x: 0, y: 0, width: 1000, height: 800), in: rects))
    }
}

final class OverlappingZoneTests: XCTestCase {
    // Two columns, with three small free zones across the top of the left one.
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    var layout: ZoneLayout {
        var l = ZoneTemplate.columns.layout(zones: 2, spacing: 0)
        l.floating = (0..<3).map { i in FloatingZone(rect: CGRect(x: Double(i) * 0.5 / 3, y: 0, width: 0.5 / 3, height: 0.5)) }
        return l
    }

    func testRectsAndLayers() {
        XCTAssertEqual(layout.zoneRects(in: screen).count, 5)
        XCTAssertEqual(layout.zoneLayers, [0, 0, 1, 2, 3])
        XCTAssertEqual(layout.zoneRects(in: screen)[3], CGRect(x: 200, y: 0, width: 200, height: 400))
    }

    func testSmallestWinsOverColumn() {
        let rects = layout.zoneRects(in: screen), layers = layout.zoneLayers
        XCTAssertEqual(ZonePicker.zones(at: CGPoint(x: 300, y: 200), in: rects, layers: layers), [3])
        // Below the free zones, the column.
        XCTAssertEqual(ZonePicker.zones(at: CGPoint(x: 300, y: 600), in: rects, layers: layers), [0])
    }

    func testTopmostRule() {
        var l = layout
        l.floating.append(FloatingZone(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.75))) // big, on top
        let rects = l.zoneRects(in: screen), layers = l.zoneLayers
        XCTAssertEqual(ZonePicker.zones(at: CGPoint(x: 300, y: 200), in: rects, layers: layers, rule: .topmost), [5])
        XCTAssertEqual(ZonePicker.zones(at: CGPoint(x: 300, y: 200), in: rects, layers: layers, rule: .smallest), [3])
    }

    func testFreeZonesSpanEachOtherNotTheColumn() {
        let rects = layout.zoneRects(in: screen), layers = layout.zoneLayers
        // On the border between free zones 2 and 3 (indices 2 and 3).
        XCTAssertEqual(Set(ZonePicker.zones(at: CGPoint(x: 201, y: 200), in: rects, layers: layers)), [2, 3])
        XCTAssertEqual(ZonePicker.span([2, 4], in: rects, layers: layers), [2, 3, 4])
    }

    func testOldLayoutsDecodeWithoutFreeZones() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"x","root":{"children":[],"fractions":[]},"spacing":8}"#
        let l = try JSONDecoder().decode(ZoneLayout.self, from: Data(json.utf8))
        XCTAssertEqual(l.floating, [])
    }
}

final class ZoneSizeEditTests: XCTestCase {
    let screen = CGRect(x: 0, y: 25, width: 1200, height: 800)

    func testWidthMovesRightLine() {
        var l = ZoneTemplate.columns.layout(zones: 3, spacing: 10)
        XCTAssertTrue(l.setSize(ofZone: 0, along: .columns, to: 630, in: screen))
        let r = l.zoneRects(in: screen)
        XCTAssertEqual(r[0].width, 630, accuracy: 1)
        XCTAssertEqual(r[2].maxX, 1190) // the far side stays
    }

    func testLastZoneMovesLeftLine() {
        var l = ZoneTemplate.columns.layout(zones: 2, spacing: 0)
        XCTAssertTrue(l.setSize(ofZone: 1, along: .columns, to: 400, in: screen))
        let r = l.zoneRects(in: screen)
        XCTAssertEqual(r[1].width, 400, accuracy: 1)
        XCTAssertEqual(r[0].width, 800, accuracy: 1)
    }

    func testNestedZoneHeight() {
        var l = ZoneTemplate.grid.layout(zones: 4, spacing: 0)
        XCTAssertTrue(l.setSize(ofZone: 0, along: .rows, to: 300, in: screen))
        XCTAssertEqual(l.zoneRects(in: screen)[0].height, 300, accuracy: 1)
        XCTAssertFalse(l.setSize(ofZone: 0, along: .rows, to: 300, in: screen) == false)
        // A full-height column has no horizontal line to move.
        var c = ZoneTemplate.columns.layout(zones: 2)
        XCTAssertFalse(c.setSize(ofZone: 0, along: .rows, to: 300, in: screen))
    }

    func testFreeZoneResizes() {
        var l = ZoneTemplate.columns.layout(zones: 2, spacing: 0)
        l.floating = [FloatingZone(rect: CGRect(x: 0.5, y: 0, width: 0.25, height: 0.5))]
        XCTAssertTrue(l.setSize(ofZone: 2, along: .columns, to: 900, in: screen))
        let f = l.zoneRects(in: screen)[2]
        XCTAssertEqual(f.width, 900, accuracy: 1)
        XCTAssertEqual(f.maxX, 1200, accuracy: 1) // pushed back on screen
    }
}
