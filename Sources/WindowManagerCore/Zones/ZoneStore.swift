import AppKit
import Combine

/// When dragging a window shows the zones.
public enum ZoneActivation: String, Codable, CaseIterable, Sendable {
    /// Only while Shift is held (normal drags keep edge snapping).
    case holdShift
    /// On every window move; holding Shift hides them for that drag.
    case always
}

/// The zone layouts, which layout each display uses, and zone preferences. Persisted as JSON in
/// UserDefaults.
///
/// Layouts are assigned per display, keyed by the display's UUID (stable across reboots and
/// rearrangements). The Spaces phase can extend the key with a Space id without changing layouts.
@MainActor
public final class ZoneStore: ObservableObject {
    private let defaults: UserDefaults

    @Published public var layouts: [ZoneLayout] { didSet { save() } }
    /// Display UUID -> layout id.
    @Published public var assignments: [String: UUID] { didSet { save() } }
    @Published public var enabled: Bool { didSet { save() } }
    @Published public var activation: ZoneActivation { didSet { save() } }
    /// Drop a window on the border between two zones to span both.
    @Published public var spanAdjacentZones: Bool { didSet { save() } }
    /// A window dragged out of a zone gets back the size it had before it was put there.
    @Published public var restoreSizeOnDragOut: Bool { didSet { save() } }

    private struct Saved: Codable {
        var layouts: [ZoneLayout]
        var assignments: [String: UUID]
        var enabled: Bool
        var activation: ZoneActivation
        var spanAdjacentZones: Bool?
        var restoreSizeOnDragOut: Bool
    }

    private static let key = "zones"

    public static var defaultLayouts: [ZoneLayout] {
        [ZoneTemplate.columns.layout(zones: 2), ZoneTemplate.columns.layout(zones: 3),
         ZoneTemplate.priorityGrid.layout(zones: 3), ZoneTemplate.grid.layout(zones: 4),
         ZoneTemplate.rows.layout(zones: 2)]
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        layouts = saved?.layouts.isEmpty == false ? saved!.layouts : Self.defaultLayouts
        assignments = saved?.assignments ?? [:]
        enabled = saved?.enabled ?? true
        activation = saved?.activation ?? .holdShift
        spanAdjacentZones = saved?.spanAdjacentZones ?? true
        restoreSizeOnDragOut = saved?.restoreSizeOnDragOut ?? true
    }

    private func save() {
        let s = Saved(layouts: layouts, assignments: assignments, enabled: enabled, activation: activation,
                      spanAdjacentZones: spanAdjacentZones, restoreSizeOnDragOut: restoreSizeOnDragOut)
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.key) }
    }

    // MARK: Lookup

    public static func key(for display: Display) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue() else { return "id-\(display.id)" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    public func layout(id: UUID) -> ZoneLayout? { layouts.first { $0.id == id } }

    /// The layout a display uses: its assignment, else the first layout.
    public func layout(for display: Display) -> ZoneLayout? {
        assignments[Self.key(for: display)].flatMap(layout(id:)) ?? layouts.first
    }

    public func assign(_ layoutID: UUID, to display: Display) {
        assignments[Self.key(for: display)] = layoutID
    }

    /// Zone rects (AX space) of a display's layout.
    public func zones(on display: Display) -> [CGRect] {
        layout(for: display)?.zoneRects(in: display.visibleFrame) ?? []
    }

    // MARK: Editing

    public func update(_ layout: ZoneLayout) {
        guard let i = layouts.firstIndex(where: { $0.id == layout.id }) else { return }
        layouts[i] = layout
    }

    @discardableResult
    public func add(_ layout: ZoneLayout) -> ZoneLayout {
        layouts.append(layout)
        return layout
    }

    public func delete(_ id: UUID) {
        guard layouts.count > 1 else { return }
        layouts.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
    }
}
