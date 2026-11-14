import Carbon.HIToolbox
import XCTest
@testable import WindowManagerCore

@MainActor
final class SettingsTests: XCTestCase {
    var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "WindowManagerTests.\(UUID().uuidString)")
    }

    func testDefaultsHaveEveryActionWithUniqueCombos() {
        let b = WindowAction.defaultBindings
        XCTAssertEqual(Set(b.keys), Set(WindowAction.allCases))
        XCTAssertEqual(Set(b.values).count, b.count)
        XCTAssertTrue(b.values.allSatisfy(\.isValidHotkey))
    }

    func testBindingsPersist() {
        let s = SettingsStore(defaults: defaults)
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey))
        s.bindings[.leftHalf] = combo
        s.bindings[.center] = nil
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.bindings[.leftHalf], combo)
        XCTAssertNil(reloaded.bindings[.center])
        XCTAssertEqual(reloaded.action(using: combo), .leftHalf)
        XCTAssertNil(reloaded.action(using: combo, except: .leftHalf))
    }

    func testComboDescription() {
        let c = KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey | optionKey))
        XCTAssertEqual(c.description, "⌃⌥←")
        XCTAssertFalse(KeyCombo(keyCode: 0, modifiers: UInt32(shiftKey)).isValidHotkey)
    }
}
