import Combine
import Foundation

/// User preferences, persisted in UserDefaults. Later phases add their settings here (snap
/// thresholds, layouts, tiling options) so every part of the app reads one observable source.
@MainActor
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let bindings = "hotkeyBindings.v1"
        static let gap = "windowGap"
    }

    /// Shortcut for each action. A missing entry means the action has no shortcut.
    @Published public var bindings: [WindowAction: KeyCombo] {
        didSet { saveBindings() }
    }

    /// Points kept between windows and screen edges.
    @Published public var gap: Double {
        didSet { defaults.set(gap, forKey: Key.gap) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bindings = Self.loadBindings(defaults) ?? WindowAction.defaultBindings
        self.gap = defaults.object(forKey: Key.gap) as? Double ?? 0
    }

    public func resetBindings() {
        bindings = WindowAction.defaultBindings
    }

    /// The action already using `combo`, other than `except`, so the UI can warn about clashes.
    public func action(using combo: KeyCombo, except: WindowAction? = nil) -> WindowAction? {
        bindings.first { $0.key != except && $0.value == combo }?.key
    }

    private static func loadBindings(_ d: UserDefaults) -> [WindowAction: KeyCombo]? {
        guard let data = d.data(forKey: Key.bindings),
              let raw = try? JSONDecoder().decode([String: KeyCombo].self, from: data) else { return nil }
        // Unknown ids (from a newer build) are dropped; new actions start without a shortcut.
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in WindowAction(rawValue: k).map { ($0, v) } })
    }

    private func saveBindings() {
        let raw = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: Key.bindings) }
    }
}
