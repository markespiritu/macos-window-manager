import AppKit
import WindowManagerCore

/// The status item and its menu.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let app: AppDelegate
    private var bindings: [WindowAction: KeyCombo] = [:]

    init(app: AppDelegate) {
        self.app = app
        super.init()
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Window Manager")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func refresh(bindings: [WindowAction: KeyCombo]? = nil) {
        if let bindings { self.bindings = bindings }
    }

    /// Rebuilt each time it opens so it reflects the current permission and shortcuts.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !app.permission.isGranted {
            let warn = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openOnboarding), keyEquivalent: "")
            warn.target = self
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warn)
            menu.addItem(.separator())
        }
        for action in WindowAction.allCases {
            let mi = NSMenuItem(title: action.title, action: #selector(runAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = action.rawValue
            mi.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil)
            if let combo = bindings[action] {
                // Shown as plain text: these are global hotkeys, not menu key equivalents.
                mi.attributedTitle = Self.title(action.title, shortcut: combo.description)
            }
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Window Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private static func title(_ text: String, shortcut: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text + "\t")
        s.append(NSAttributedString(string: shortcut, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 200)]
        s.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: s.length))
        s.addAttribute(.font, value: NSFont.menuFont(ofSize: 0), range: NSRange(location: 0, length: s.length))
        return s
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = WindowAction(rawValue: raw) else { return }
        // The menu took focus from the target app; give it back a beat to settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.app.perform(action) }
    }

    @objc private func openSettings() { app.showSettings() }
    @objc private func openOnboarding() { app.showOnboarding() }
}
