import AppKit
import WindowManagerCore

/// The status item and its menu.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let app: AppDelegate

    init(app: AppDelegate) {
        self.app = app
        super.init()
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Window Manager")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// Rebuilt each time it opens so it reflects the current permission and settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !app.permission.isGranted {
            let warn = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openOnboarding), keyEquivalent: "")
            warn.target = self
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warn)
            menu.addItem(.separator())
        }
        let snap = NSMenuItem(title: "Snap Windows", action: #selector(toggleSnapping), keyEquivalent: "")
        snap.target = self
        snap.state = app.settings.snappingEnabled ? .on : .off
        menu.addItem(snap)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Window Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleSnapping() { app.settings.snappingEnabled.toggle() }
    @objc private func openSettings() { app.showSettings() }
    @objc private func openOnboarding() { app.showOnboarding() }
}
