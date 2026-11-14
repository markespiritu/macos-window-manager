import Carbon.HIToolbox
import Foundation

/// A key plus modifiers, stored in Carbon terms (virtual key code, Carbon modifier mask) because
/// that is what RegisterEventHotKey takes. Codable so bindings persist in UserDefaults.
public struct KeyCombo: Codable, Hashable, Sendable, CustomStringConvertible {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Hotkeys need at least one of Control, Option or Command; Shift alone would steal typing.
    public var isValidHotkey: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    /// "⌃⌥←" style, in the standard macOS modifier order.
    public var description: String { Self.modifierSymbols(modifiers) + Self.keyName(keyCode) }

    public static func modifierSymbols(_ m: UInt32) -> String {
        var s = ""
        if m & UInt32(controlKey) != 0 { s += "⌃" }
        if m & UInt32(optionKey) != 0 { s += "⌥" }
        if m & UInt32(shiftKey) != 0 { s += "⇧" }
        if m & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    static let specialKeys: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Name of a key on the current keyboard layout ("A", "Ö", "/"), falling back to the code.
    public static func keyName(_ code: UInt32) -> String {
        if let s = specialKeys[Int(code)] { return s }
        if let s = translate(code), !s.isEmpty { return s.uppercased() }
        return "Key \(code)"
    }

    private static func translate(_ code: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var len = 0
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &len, &chars)
            return status == noErr ? String(utf16CodeUnits: chars, count: len) : nil
        }
    }
}
