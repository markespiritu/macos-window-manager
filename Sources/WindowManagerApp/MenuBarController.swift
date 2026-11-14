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
        // A larger point size and medium weight: at the default size this wide symbol came out
        // shorter than the other menu bar icons, with thin, soft-looking lines.
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Window Manager")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.imageScaling = .scaleNone // drawn at its own size, never resampled
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
        addZoneLayouts(to: menu)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Window Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// "Zone Layout" items: the layouts, checked for the display they are on. With one display
    /// they are listed directly; with several, each display gets a submenu.
    private func addZoneLayouts(to menu: NSMenu) {
        let store = app.zoneStore
        guard store.enabled else { return }
        let displays = DisplayService.displays
        func items(for display: Display) -> [NSMenuItem] {
            let current = store.layout(for: display)?.id
            return store.layouts.map { layout in
                let item = NSMenuItem(title: layout.name, action: #selector(pickLayout(_:)), keyEquivalent: "")
                item.target = self
                item.state = layout.id == current ? .on : .off
                item.representedObject = LayoutChoice(layout: layout.id, display: display.id)
                if displays.count == 1 { item.indentationLevel = 1 }
                return item
            }
        }
        if displays.count == 1, let d = displays.first {
            let header = NSMenuItem(title: "Zone Layout", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            items(for: d).forEach(menu.addItem)
        } else {
            for d in displays {
                let item = NSMenuItem(title: "Zone Layout: \(d.name)", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                items(for: d).forEach(sub.addItem)
                item.submenu = sub
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
    }

    private final class LayoutChoice: NSObject {
        let layout: UUID
        let display: CGDirectDisplayID
        init(layout: UUID, display: CGDirectDisplayID) { self.layout = layout; self.display = display }
    }

    @objc private func pickLayout(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? LayoutChoice,
              let display = DisplayService.displays.first(where: { $0.id == choice.display }) else { return }
        app.zones.apply(choice.layout, to: display)
    }

    @objc private func toggleSnapping() { app.settings.snappingEnabled.toggle() }
    @objc private func openSettings() { app.showSettings() }
    @objc private func openOnboarding() { app.showOnboarding() }
}
