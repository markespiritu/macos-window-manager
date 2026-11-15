import Combine
import Foundation

/// User preferences, persisted in UserDefaults. Later phases add their settings here so every part
/// of the app reads one observable source.
@MainActor
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published public var snappingEnabled: Bool { didSet { defaults.set(snappingEnabled, forKey: "snappingEnabled") } }
    /// How close, in points, an edge must come to a screen edge before it snaps. Stored under the
    /// original "snapDistance" key, which used to cover windows too.
    @Published public var snapDistance: Double { didSet { defaults.set(snapDistance, forKey: "snapDistance") } }
    /// How close an edge must come to another window's edge before it snaps.
    @Published public var windowSnapDistance: Double { didSet { defaults.set(windowSnapDistance, forKey: "windowSnapDistance") } }
    /// Snap a moved window to the centre of the screen (off by default, as in KWin).
    @Published public var snapToCenter: Bool { didSet { defaults.set(snapToCenter, forKey: "snapToCenter") } }
    /// How close the window's centre must come to the screen's centre before it snaps.
    @Published public var centerSnapDistance: Double { didSet { defaults.set(centerSnapDistance, forKey: "centerSnapDistance") } }
    @Published public var snapToScreenEdges: Bool { didSet { defaults.set(snapToScreenEdges, forKey: "snapToScreenEdges") } }
    @Published public var snapToWindows: Bool { didSet { defaults.set(snapToWindows, forKey: "snapToWindows") } }
    /// Held during a move or resize, turns snapping off until it is released (nil: no key).
    /// Never the same as the zone key; see `ModifierKey.snapBypass(_:zoneKey:)`.
    @Published public var snapBypassKey: ModifierKey? {
        didSet { defaults.set(snapBypassKey?.rawValue ?? "none", forKey: "snapBypassKey") }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snappingEnabled = defaults.object(forKey: "snappingEnabled") as? Bool ?? true
        let screen = defaults.object(forKey: "snapDistance") as? Double ?? 10
        snapDistance = screen
        // Existing setups keep their single distance for windows until it is changed.
        let window = defaults.object(forKey: "windowSnapDistance") as? Double ?? screen
        windowSnapDistance = window
        // Save it now so it stops following the screen distance from here on.
        defaults.set(window, forKey: "windowSnapDistance")
        snapToCenter = defaults.object(forKey: "snapToCenter") as? Bool ?? false
        centerSnapDistance = defaults.object(forKey: "centerSnapDistance") as? Double ?? 10
        snapToScreenEdges = defaults.object(forKey: "snapToScreenEdges") as? Bool ?? true
        snapToWindows = defaults.object(forKey: "snapToWindows") as? Bool ?? true
        switch defaults.string(forKey: "snapBypassKey") {
        case nil: snapBypassKey = .command
        case let saved?: snapBypassKey = ModifierKey(rawValue: saved) // "none": nil
        }
    }

    public var snapEngine: SnapEngine {
        SnapEngine(screenDistance: CGFloat(snapDistance), windowDistance: CGFloat(windowSnapDistance),
                   centerDistance: CGFloat(centerSnapDistance),
                   snapToScreen: snapToScreenEdges, snapToWindows: snapToWindows, snapToCenter: snapToCenter)
    }
}
