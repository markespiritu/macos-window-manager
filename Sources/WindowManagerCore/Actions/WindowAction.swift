import Carbon.HIToolbox

/// A command that acts on the focused window. New phases add cases here (thirds, next display,
/// apply layout, tile commands) and they get a hotkey slot and a settings row for free.
public enum WindowAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf, maximize, center, restore

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .maximize: "Maximize"
        case .center: "Center"
        case .restore: "Restore"
        }
    }

    /// SF Symbol for menus and settings rows.
    public var symbolName: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .maximize: "rectangle.fill"
        case .center: "rectangle.center.inset.filled"
        case .restore: "arrow.uturn.backward"
        }
    }

    /// Default shortcuts: Control-Option plus arrows / Return / C / Delete.
    public var defaultCombo: KeyCombo? {
        let mods = UInt32(controlKey | optionKey)
        switch self {
        case .leftHalf: return KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: mods)
        case .rightHalf: return KeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: mods)
        case .topHalf: return KeyCombo(keyCode: UInt32(kVK_UpArrow), modifiers: mods)
        case .bottomHalf: return KeyCombo(keyCode: UInt32(kVK_DownArrow), modifiers: mods)
        case .maximize: return KeyCombo(keyCode: UInt32(kVK_Return), modifiers: mods)
        case .center: return KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: mods)
        case .restore: return KeyCombo(keyCode: UInt32(kVK_Delete), modifiers: mods)
        }
    }

    public static var defaultBindings: [WindowAction: KeyCombo] {
        Dictionary(uniqueKeysWithValues: allCases.compactMap { a in a.defaultCombo.map { (a, $0) } })
    }
}
