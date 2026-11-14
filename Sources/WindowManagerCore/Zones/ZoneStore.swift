import AppKit
import Combine

/// When dragging a window shows the zones.
public enum ZoneActivation: String, Codable, CaseIterable, Sendable {
    /// Only while the zone modifier is held (normal drags keep edge snapping).
    case hold = "holdShift"
    /// On every window move; holding the zone modifier hides them for that drag.
    case always
}

/// The key that shows (or, in `always` mode, hides) zones during a drag.
public enum ZoneModifier: String, Codable, CaseIterable, Identifiable, Sendable {
    case option, shift, command, control

    public var id: String { rawValue }

    public var flag: CGEventFlags {
        switch self {
        case .option: .maskAlternate
        case .shift: .maskShift
        case .command: .maskCommand
        case .control: .maskControl
        }
    }

    public var label: String {
        switch self {
        case .option: "⌥ Option"
        case .shift: "⇧ Shift"
        case .command: "⌘ Command"
        case .control: "⌃ Control"
        }
    }

    /// The key that spans several zones: Control, or Shift when Control is the zone key.
    public var spanModifier: ZoneModifier { self == .control ? .shift : .control }
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
    @Published public var modifier: ZoneModifier { didSet { save() } }
    /// Drop a window on the border between two zones to span both.
    @Published public var spanAdjacentZones: Bool { didSet { save() } }
    /// A window dragged out of a zone gets back the size it had before it was put there.
    @Published public var restoreSizeOnDragOut: Bool { didSet { save() } }
    /// Which zone wins where zones overlap.
    @Published public var overlapRule: ZoneOverlapRule { didSet { save() } }

    private struct Saved: Codable {
        var layouts: [ZoneLayout]
        var assignments: [String: UUID]
        var enabled: Bool
        var activation: ZoneActivation
        var modifier: ZoneModifier?
        var spanAdjacentZones: Bool?
        var restoreSizeOnDragOut: Bool
        var overlapRule: ZoneOverlapRule?
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
        activation = saved?.activation ?? .hold
        modifier = saved?.modifier ?? .option
        spanAdjacentZones = saved?.spanAdjacentZones ?? true
        restoreSizeOnDragOut = saved?.restoreSizeOnDragOut ?? true
        overlapRule = saved?.overlapRule ?? .smallest
    }

    private func save() {
        let s = Saved(layouts: layouts, assignments: assignments, enabled: enabled, activation: activation, modifier: modifier,
                      spanAdjacentZones: spanAdjacentZones, restoreSizeOnDragOut: restoreSizeOnDragOut,
                      overlapRule: overlapRule)
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

    /// Layer of each zone of a display's layout, parallel to `zones(on:)`.
    public func zoneLayers(on display: Display) -> [Int] {
        layout(for: display)?.zoneLayers ?? []
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

    /// Replaces every layout with the defaults and clears the per-display choices.
    public func resetLayouts() {
        layouts = Self.defaultLayouts
        assignments = [:]
    }

    public func delete(_ id: UUID) {
        guard layouts.count > 1 else { return }
        layouts.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
    }
}
