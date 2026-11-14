import CoreGraphics
import Foundation

/// How a split lays out its children.
public enum SplitAxis: String, Codable, Hashable, Sendable {
    /// Side by side, left to right.
    case columns
    /// Stacked, top to bottom.
    case rows

    public var other: SplitAxis { self == .columns ? .rows : .columns }
}

/// A zone layout is a tree: a leaf is one zone, a split divides its area among its children by
/// fractions that add up to 1. Every layout (templates and custom ones) is stored this way, so the
/// editor's split / merge / drag-divider operations work on all of them.
///
/// Leaves are numbered depth-first, which for the usual layouts is reading order (left to right,
/// top to bottom). That number is the zone's index everywhere (overlay labels, hotkeys).
public struct ZoneNode: Codable, Hashable, Sendable {
    /// nil for a leaf (a zone).
    public var axis: SplitAxis?
    public var children: [ZoneNode]
    public var fractions: [Double]

    public static let zone = ZoneNode(axis: nil, children: [], fractions: [])

    public init(axis: SplitAxis?, children: [ZoneNode], fractions: [Double]) {
        self.axis = axis
        self.children = children
        self.fractions = fractions
    }

    /// A split into equal parts.
    public static func split(_ axis: SplitAxis, _ children: [ZoneNode]) -> ZoneNode {
        ZoneNode(axis: axis, children: children, fractions: Array(repeating: 1 / Double(children.count), count: children.count))
    }

    public static func split(_ axis: SplitAxis, _ children: [ZoneNode], fractions: [Double]) -> ZoneNode {
        let total = fractions.reduce(0, +)
        return ZoneNode(axis: axis, children: children, fractions: fractions.map { $0 / total })
    }

    public var isLeaf: Bool { axis == nil || children.isEmpty }

    public var zoneCount: Int { isLeaf ? 1 : children.reduce(0) { $0 + $1.zoneCount } }

    // MARK: Geometry

    /// The zones' rects inside `rect`, in leaf order. `spacing` is the gap between zones and
    /// around the outside, in the same units as `rect`.
    public func zoneRects(in rect: CGRect, spacing: CGFloat = 0) -> [CGRect] {
        var out: [CGRect] = []
        collect(in: rect.insetBy(dx: spacing, dy: spacing), spacing: spacing, into: &out)
        return out.map(\.integralized)
    }

    private func collect(in rect: CGRect, spacing: CGFloat, into out: inout [CGRect]) {
        guard let axis, !children.isEmpty else { out.append(rect); return }
        for (i, r) in childRects(in: rect, axis: axis, spacing: spacing).enumerated() {
            children[i].collect(in: r, spacing: spacing, into: &out)
        }
    }

    /// Child areas of this split: the gaps between children are taken off first, then the rest is
    /// shared by fraction.
    func childRects(in rect: CGRect, axis: SplitAxis, spacing: CGFloat) -> [CGRect] {
        let n = children.count
        let length = axis == .columns ? rect.width : rect.height
        let usable = max(length - spacing * CGFloat(n - 1), 0)
        var pos = axis == .columns ? rect.minX : rect.minY
        return (0..<n).map { i in
            let size = usable * CGFloat(fractions[i])
            defer { pos += size + spacing }
            return axis == .columns
                ? CGRect(x: pos, y: rect.minY, width: size, height: rect.height)
                : CGRect(x: rect.minX, y: pos, width: rect.width, height: size)
        }
    }

    // MARK: Editing

    /// A divider between children `index` and `index + 1` of the split at `path`.
    public struct Divider: Hashable, Sendable, Identifiable {
        /// Stable while the divider is dragged (its rect changes, its place in the tree does not).
        public var id: String { "\(path)-\(index)" }
        public let path: [Int]
        public let index: Int
        public let axis: SplitAxis
        /// The gap the divider occupies (at least a thin line when spacing is 0).
        public let rect: CGRect
        /// The area of the whole split, needed to turn a drag position into fractions.
        public let splitRect: CGRect
    }

    public func dividers(in rect: CGRect, spacing: CGFloat = 0) -> [Divider] {
        var out: [Divider] = []
        collectDividers(in: rect.insetBy(dx: spacing, dy: spacing), spacing: spacing, path: [], into: &out)
        return out
    }

    private func collectDividers(in rect: CGRect, spacing: CGFloat, path: [Int], into out: inout [Divider]) {
        guard let axis, !children.isEmpty else { return }
        let rects = childRects(in: rect, axis: axis, spacing: spacing)
        for i in 0..<rects.count - 1 {
            let a = rects[i], b = rects[i + 1]
            let gap = axis == .columns
                ? CGRect(x: a.maxX, y: rect.minY, width: max(b.minX - a.maxX, 0), height: rect.height)
                : CGRect(x: rect.minX, y: a.maxY, width: rect.width, height: max(b.minY - a.maxY, 0))
            out.append(Divider(path: path, index: i, axis: axis, rect: gap, splitRect: rect))
        }
        for (i, r) in rects.enumerated() {
            children[i].collectDividers(in: r, spacing: spacing, path: path + [i], into: &out)
        }
    }

    /// Path (child indices from the root) of each leaf, in leaf order.
    public var leafPaths: [[Int]] {
        if isLeaf { return [[]] }
        return children.enumerated().flatMap { i, c in c.leafPaths.map { [i] + $0 } }
    }

    subscript(path: ArraySlice<Int>) -> ZoneNode {
        get { path.isEmpty ? self : children[path.first!][path.dropFirst()] }
        set {
            if path.isEmpty { self = newValue } else { children[path.first!][path.dropFirst()] = newValue }
        }
    }

    /// Splits zone `zone` in two along `axis`. When its parent already splits that way, the new
    /// zone becomes a sibling (so splitting a column again gives three equal-ish columns, not a
    /// nested split).
    public mutating func split(zone: Int, along axis: SplitAxis) {
        let paths = leafPaths
        guard paths.indices.contains(zone) else { return }
        let path = paths[zone]
        if let last = path.last, self[path.dropLast()].axis == axis {
            var parent = self[path.dropLast()]
            let half = parent.fractions[last] / 2
            parent.fractions[last] = half
            parent.fractions.insert(half, at: last + 1)
            parent.children.insert(.zone, at: last + 1)
            self[path.dropLast()] = parent
        } else {
            self[path[...]] = .split(axis, [.zone, .zone])
        }
    }

    /// Removes zone `zone`; its space goes to the neighbour before it (or after, for the first).
    /// A split left with one child is replaced by that child. The last zone cannot be removed.
    public mutating func remove(zone: Int) {
        let paths = leafPaths
        guard paths.count > 1, paths.indices.contains(zone), let last = paths[zone].last else { return }
        let parentPath = paths[zone].dropLast()
        var parent = self[parentPath]
        let freed = parent.fractions.remove(at: last)
        parent.children.remove(at: last)
        parent.fractions[max(last - 1, 0)] += freed
        if parent.children.count == 1 { parent = parent.children[0] }
        self[parentPath] = parent
        normalize()
    }

    /// Moves a divider so the boundary sits at `position` (x for columns, y for rows, in the
    /// coordinates `dividers(in:)` was called with). Each side keeps at least `minFraction`
    /// of the split.
    public mutating func move(_ d: Divider, to position: CGFloat, spacing: CGFloat = 0, minFraction: Double = 0.05) {
        var split = self[d.path[...]]
        guard split.axis == d.axis, split.fractions.indices.contains(d.index + 1) else { return }
        let n = split.children.count
        let length = d.axis == .columns ? d.splitRect.width : d.splitRect.height
        let origin = d.axis == .columns ? d.splitRect.minX : d.splitRect.minY
        let usable = max(length - spacing * CGFloat(n - 1), 1)
        // Fraction of the split before the boundary, not counting gaps.
        let before = split.fractions[..<d.index].reduce(0, +)
        let gapsBefore = spacing * CGFloat(d.index) + spacing / 2
        let target = Double((position - origin - gapsBefore) / usable)
        let pair = split.fractions[d.index] + split.fractions[d.index + 1]
        let a = min(max(target - before, minFraction), pair - minFraction)
        guard a > 0, pair - a > 0 else { return }
        split.fractions[d.index] = a
        split.fractions[d.index + 1] = pair - a
        self[d.path[...]] = split
    }

    /// Collapses single-child splits and nested splits along the same axis, and renormalizes
    /// fractions. Keeps the tree minimal after edits.
    public mutating func normalize() {
        guard axis != nil else { children = []; fractions = []; return }
        for i in children.indices { children[i].normalize() }
        if children.count == 1 { self = children[0]; return }
        var kids: [ZoneNode] = [], fr: [Double] = []
        for (c, f) in zip(children, fractions) {
            if c.axis == axis {
                kids += c.children
                fr += c.fractions.map { $0 * f }
            } else {
                kids.append(c); fr.append(f)
            }
        }
        let total = fr.reduce(0, +)
        children = kids
        fractions = total > 0 ? fr.map { $0 / total } : fr
    }
}

/// A free-form zone that sits on top of the split zones (and of earlier free zones).
public struct FloatingZone: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Position and size as fractions (0...1) of the display's usable area.
    public var rect: CGRect

    public init(id: UUID = UUID(), rect: CGRect) {
        self.id = id
        self.rect = rect
    }

    public func frame(in area: CGRect) -> CGRect {
        CGRect(x: area.minX + rect.minX * area.width, y: area.minY + rect.minY * area.height,
               width: rect.width * area.width, height: rect.height * area.height).integralized
    }

    /// The fractional rect for a frame inside `area`.
    public static func fraction(of frame: CGRect, in area: CGRect) -> CGRect {
        CGRect(x: (frame.minX - area.minX) / max(area.width, 1), y: (frame.minY - area.minY) / max(area.height, 1),
               width: frame.width / max(area.width, 1), height: frame.height / max(area.height, 1))
    }
}

/// A named zone layout: the split zones (layer 0) plus free zones stacked above them, each on its
/// own layer in order (the last one is on top).
///
/// Zones are numbered split zones first, then free zones bottom to top.
public struct ZoneLayout: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var root: ZoneNode
    /// Gap between split zones and around the edge of the screen, in points.
    public var spacing: Double
    public var floating: [FloatingZone]

    public init(id: UUID = UUID(), name: String, root: ZoneNode, spacing: Double = 8, floating: [FloatingZone] = []) {
        self.id = id
        self.name = name
        self.root = root
        self.spacing = spacing
        self.floating = floating
    }

    private enum CodingKeys: String, CodingKey { case id, name, root, spacing, floating }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        root = try c.decode(ZoneNode.self, forKey: .root)
        spacing = try c.decode(Double.self, forKey: .spacing)
        // Drop degenerate free zones (nothing could be dropped on them, and they cannot be grabbed).
        floating = (try c.decodeIfPresent([FloatingZone].self, forKey: .floating) ?? [])
            .filter { $0.rect.width >= 0.01 && $0.rect.height >= 0.01 }
    }

    public var zoneCount: Int { root.zoneCount + floating.count }

    /// Every zone's rect, split zones first, then free zones bottom to top.
    public func zoneRects(in frame: CGRect) -> [CGRect] {
        root.zoneRects(in: frame, spacing: CGFloat(spacing)) + floating.map { $0.frame(in: frame) }
    }

    /// The layer of each zone, parallel to `zoneRects`: 0 for split zones, 1... for free zones.
    public var zoneLayers: [Int] {
        Array(repeating: 0, count: root.zoneCount) + floating.indices.map { $0 + 1 }
    }
}

/// Which zone a drag picks where zones overlap.
public enum ZoneOverlapRule: String, Codable, CaseIterable, Sendable {
    case smallest
    case topmost
}

/// Starting points for new layouts.
public enum ZoneTemplate: String, CaseIterable, Identifiable, Sendable {
    case columns, rows, grid, priorityGrid

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .columns: "Columns"
        case .rows: "Rows"
        case .grid: "Grid"
        case .priorityGrid: "Priority Grid"
        }
    }

    public var defaultZoneCount: Int {
        switch self {
        case .columns: 3
        case .rows: 2
        case .grid: 4
        case .priorityGrid: 3
        }
    }

    public func root(zones n: Int) -> ZoneNode {
        let n = max(n, 1)
        switch self {
        case .columns:
            return n == 1 ? .zone : .split(.columns, Array(repeating: .zone, count: n))
        case .rows:
            return n == 1 ? .zone : .split(.rows, Array(repeating: .zone, count: n))
        case .grid:
            // As square as possible, columns first; the last row takes what is left over.
            let cols = Int(Double(n).squareRoot().rounded(.up))
            let rows = Int((Double(n) / Double(cols)).rounded(.up))
            var left = n
            let rowNodes: [ZoneNode] = (0..<rows).map { _ in
                let c = min(cols, left); left -= c
                return c == 1 ? .zone : .split(.columns, Array(repeating: .zone, count: c))
            }
            return rows == 1 ? rowNodes[0] : .split(.rows, rowNodes)
        case .priorityGrid:
            // A wide middle zone between two side columns; extra zones stack in the sides.
            if n <= 2 { return ZoneTemplate.columns.root(zones: n) }
            let extra = n - 3
            let leftCount = 1 + (extra + 1) / 2, rightCount = 1 + extra / 2
            func side(_ k: Int) -> ZoneNode { k == 1 ? .zone : .split(.rows, Array(repeating: .zone, count: k)) }
            return .split(.columns, [side(leftCount), .zone, side(rightCount)], fractions: [1, 2, 1])
        }
    }

    public func layout(zones: Int? = nil, spacing: Double = 8) -> ZoneLayout {
        let n = zones ?? defaultZoneCount
        let suffix = self == .grid || self == .priorityGrid ? " (\(n))" : " \(n)"
        return ZoneLayout(name: name + suffix, root: root(zones: n), spacing: spacing)
    }
}

/// Snapping for free zones in the editor: moving edges stick to nearby guide lines (other zones'
/// edges, screen fractions).
public enum GuideSnap {
    /// - Parameters:
    ///   - edges: the edges being dragged; `.all` for a move (the rect shifts, keeping its size).
    ///   - xs, ys: vertical and horizontal guide lines.
    public static func snap(_ r: CGRect, edges: Edges, xs: [CGFloat], ys: [CGFloat], threshold: CGFloat) -> CGRect {
        func nearest(_ v: CGFloat, _ lines: [CGFloat]) -> CGFloat? {
            lines.map { $0 - v }.filter { abs($0) <= threshold }.min { abs($0) < abs($1) }
        }
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if edges == .all {
            let dx = [nearest(minX, xs), nearest(maxX, xs)].compactMap { $0 }.min { abs($0) < abs($1) } ?? 0
            let dy = [nearest(minY, ys), nearest(maxY, ys)].compactMap { $0 }.min { abs($0) < abs($1) } ?? 0
            return r.offsetBy(dx: dx, dy: dy)
        }
        if edges.contains(.left), let d = nearest(minX, xs) { minX += d }
        if edges.contains(.right), let d = nearest(maxX, xs) { maxX += d }
        if edges.contains(.top), let d = nearest(minY, ys) { minY += d }
        if edges.contains(.bottom), let d = nearest(maxY, ys) { maxY += d }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
