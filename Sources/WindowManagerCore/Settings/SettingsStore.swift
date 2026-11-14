import Combine
import Foundation

/// User preferences, persisted in UserDefaults. Later phases add their settings here so every part
/// of the app reads one observable source.
@MainActor
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published public var snappingEnabled: Bool { didSet { defaults.set(snappingEnabled, forKey: "snappingEnabled") } }
    /// How close, in points, an edge must come to a target before it snaps.
    @Published public var snapDistance: Double { didSet { defaults.set(snapDistance, forKey: "snapDistance") } }
    /// How far a snapped edge must be pulled before it lets go.
    @Published public var releaseDistance: Double { didSet { defaults.set(releaseDistance, forKey: "releaseDistance") } }
    /// Fast drags glide past edges; snapping only catches when the window slows down.
    @Published public var snapOnlyWhenSlow: Bool { didSet { defaults.set(snapOnlyWhenSlow, forKey: "snapOnlyWhenSlow") } }
    @Published public var snapToScreenEdges: Bool { didSet { defaults.set(snapToScreenEdges, forKey: "snapToScreenEdges") } }
    @Published public var snapToWindows: Bool { didSet { defaults.set(snapToWindows, forKey: "snapToWindows") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snappingEnabled = defaults.object(forKey: "snappingEnabled") as? Bool ?? true
        snapDistance = defaults.object(forKey: "snapDistance") as? Double ?? 8
        releaseDistance = defaults.object(forKey: "releaseDistance") as? Double ?? 24
        snapOnlyWhenSlow = defaults.object(forKey: "snapOnlyWhenSlow") as? Bool ?? true
        snapToScreenEdges = defaults.object(forKey: "snapToScreenEdges") as? Bool ?? true
        snapToWindows = defaults.object(forKey: "snapToWindows") as? Bool ?? true
    }

    public var snapEngine: SnapEngine {
        SnapEngine(distance: CGFloat(snapDistance), releaseDistance: CGFloat(releaseDistance), snapToScreen: snapToScreenEdges, snapToWindows: snapToWindows)
    }
}
