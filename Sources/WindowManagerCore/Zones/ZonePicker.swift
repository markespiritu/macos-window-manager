import CoreGraphics

/// Which zones a drag selects, as pure geometry (AX space).
public enum ZonePicker {
    /// Zones selected by the cursor at `point`. The zone under it, plus (when `spanAdjacent`) any
    /// zone within `radius`, so hovering over the border between two zones selects both. In a gap
    /// or just outside the zones, the nearest zone within `radius` is selected.
    public static func zones(at point: CGPoint, in rects: [CGRect], radius: CGFloat = 16, spanAdjacent: Bool = true) -> [Int] {
        let distances = rects.map { distance(from: point, to: $0) }
        let near = distances.indices.filter { distances[$0] <= radius }
        if near.isEmpty { return [] }
        let inside = near.filter { distances[$0] == 0 }
        if spanAdjacent {
            // Only span when the cursor is really on a border: within radius/2 of the zone it is in.
            guard let home = inside.first else { return near }
            let edge = edgeDistance(from: point, inside: rects[home])
            return edge <= radius / 2 ? near : [home]
        }
        if let home = inside.first { return [home] }
        return [near.min { distances[$0] < distances[$1] }!]
    }

    /// Every zone that overlaps the bounding box of the given zones, so selecting two opposite
    /// corners of a grid fills in everything between them.
    public static func span(_ indices: [Int], in rects: [CGRect]) -> [Int] {
        guard let box = bounds(indices, in: rects) else { return [] }
        let inner = box.insetBy(dx: 1, dy: 1)
        return rects.indices.filter { rects[$0].intersects(inner) }
    }

    /// The frame a window gets when dropped on these zones.
    public static func bounds(_ indices: [Int], in rects: [CGRect]) -> CGRect? {
        let rs = indices.filter(rects.indices.contains).map { rects[$0] }
        guard let first = rs.first else { return nil }
        return rs.dropFirst().reduce(first) { $0.union($1) }
    }

    /// The zone a window is in: the one it overlaps most, if that is most of the zone.
    public static func zone(containing frame: CGRect, in rects: [CGRect]) -> Int? {
        let scores = rects.map { r -> CGFloat in
            let i = r.intersectionArea(with: frame)
            let union = r.width * r.height + frame.width * frame.height - i
            return union > 0 ? i / union : 0
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0.5 else { return nil }
        return best
    }

    static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func edgeDistance(from p: CGPoint, inside r: CGRect) -> CGFloat {
        min(p.x - r.minX, r.maxX - p.x, p.y - r.minY, r.maxY - p.y)
    }
}
