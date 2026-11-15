import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import WindowManagerCore

/// Owns the app's long-lived objects and wires them together.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    let settings = SettingsStore()
    let permission = AccessibilityPermission()
    let zoneStore = ZoneStore()
    /// Undo history of the zone layout editor, one per layout.
    private(set) lazy var zoneHistory = ZoneEditHistory(store: zoneStore)
    private(set) var snapper: SnapController!
    private(set) var zones: ZoneController!
    private let hotkeys = HotkeyCenter()

    private var menuBar: MenuBarController!
    private var onboarding: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        zones = ZoneController(store: zoneStore)
        snapper = SnapController(engine: settings.snapEngine, isEnabled: settings.snappingEnabled || zoneStore.enabled)
        snapper.snapping = settings.snappingEnabled
        snapper.zones = zones
        // The snapping bypass key, never the zone key (a zone key set to Command before the bypass
        // key existed moves the bypass key's default elsewhere).
        if let key = settings.snapBypassKey, key == zoneStore.modifier {
            settings.snapBypassKey = ModifierKey.freeSnapBypass(zoneKey: key)
        }
        settings.$snapBypassKey.combineLatest(zoneStore.$modifier)
            .sink { [weak self] key, zoneKey in self?.snapper.bypassKey = ModifierKey.snapBypass(key, zoneKey: zoneKey) }
            .store(in: &cancellables)
        menuBar = MenuBarController(app: self)
        NSApp.mainMenu = makeMainMenu()

        // Any snapping setting change rebuilds the engine (on the next run loop pass, after the
        // @Published value has been stored).
        Publishers.MergeMany(settings.$snapDistance.map { _ in () }.eraseToAnyPublisher(),
                             settings.$snapToScreenEdges.map { _ in () }.eraseToAnyPublisher(),
                             settings.$snapToWindows.map { _ in () }.eraseToAnyPublisher(),
                             settings.$releaseDistance.map { _ in () }.eraseToAnyPublisher())
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.snapper.engine = self.settings.snapEngine
            }
            .store(in: &cancellables)
        // The event tap runs while either snapping or zones need it.
        settings.$snappingEnabled.combineLatest(zoneStore.$enabled)
            .sink { [weak self] snap, zones in
                guard let self else { return }
                self.snapper.snapping = snap
                if self.snapper.isEnabled != (snap || zones) { self.snapper.isEnabled = snap || zones }
                self.updateHotkeys(zones: zones)
            }
            .store(in: &cancellables)
        permission.$isGranted
            .removeDuplicates()
            .sink { [weak self] granted in
                guard granted else { return }
                self?.onboarding?.close()
                self?.snapper.start() // the event tap can only be created once access is granted
            }
            .store(in: &cancellables)

        if !permission.isGranted { showOnboarding() }
        // Dev aid: `open "Window Manager.app" --args -openSettingsOnLaunch YES`
        if UserDefaults.standard.bool(forKey: "openSettingsOnLaunch") { showSettings() }
    }

    /// Opening the app again while it runs (Finder, Spotlight, `open`) shows Settings. Useful when
    /// the menu bar icon is hidden behind the notch or by a menu bar manager.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if permission.isGranted { showSettings() } else { showOnboarding() }
        return false
    }

    // MARK: Hotkeys

    /// ⌃⌥⌘← / → moves the focused window between zones. Only registered while zones are on.
    /// (No layout-switching hotkeys: Marky keeps ⌃⌥⌘1–9 for something else.)
    private func updateHotkeys(zones on: Bool) {
        guard on else { hotkeys.setBindings([]); return }
        let mods = UInt32(controlKey | optionKey | cmdKey)
        var bindings: [HotkeyCenter.Binding] = []
        bindings.append(HotkeyCenter.Binding(id: "zones.next", combo: KeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: mods)) { [weak self] in
            self?.zones.moveFocusedWindow(by: 1)
        })
        bindings.append(HotkeyCenter.Binding(id: "zones.previous", combo: KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: mods)) { [weak self] in
            self?.zones.moveFocusedWindow(by: -1)
        })
        let failed = hotkeys.setBindings(bindings)
        if !failed.isEmpty { NSLog("Window Manager: could not register hotkeys %@", failed.joined(separator: ", ")) }
    }

    // MARK: Windows

    func showOnboarding() {
        if onboarding == nil {
            let w = makeWindow(title: "Welcome", content: OnboardingView(permission: permission))
            w.isReleasedWhenClosed = false
            onboarding = w
        }
        permission.startPolling()
        present(onboarding!)
    }

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(app: self, settings: settings, permission: permission)
            let w = UndoWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            // ⌘Z / ⇧⌘Z and Edit › Undo / Redo: the zone editor's history for the layout it shows,
            // while the Zones tab is open.
            w.undoProvider = { [weak self] in self?.zoneHistory.activeManager }
            w.isReleasedWhenClosed = false
            // Resizable, so the zone editor can be made large; the content sets only a minimum.
            (w.contentViewController as? NSHostingController<SettingsView>)?.sizingOptions = [.minSize]
            w.styleMask.insert(.resizable)
            w.setContentSize(NSSize(width: 900, height: 760))
            w.center()
            w.setFrameAutosaveName("Settings") // restores the last size and place, if any
            w.delegate = self
            settingsWindow = w
        }
        // A regular app while Settings is open, so the menu bar (Edit › Undo / Redo) shows.
        NSApp.setActivationPolicy(.regular)
        present(settingsWindow!)
    }

    // MARK: NSWindowDelegate (Settings)

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory) // back to a menu bar only app
    }

    // MARK: Main menu

    /// Shown while Settings is open. The Edit menu also gives text fields their usual shortcuts.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let settings = item("Settings…", #selector(openSettingsFromMenu), ",")
        settings.target = self
        submenu("Window Manager", [
            settings,
            .separator(),
            item("Hide Window Manager", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Window Manager", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let windowMenu = [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ]
        submenu("Window", windowMenu)
        NSApp.windowsMenu = main.items.last?.submenu
        return main
    }

    @objc private func openSettingsFromMenu() { showSettings() }

    private func makeWindow<V: View>(title: String, content: V) -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: content))
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.center()
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}


/// A window whose undo manager is chosen by `undoProvider` each time it is asked for, falling
/// back to the window's own. (The delegate's windowWillReturnUndoManager is not asked again once
/// the window has handed one out.) Undo / Redo and their menu titles are handled here too, so
/// they always use that manager.
final class UndoWindow: NSWindow {
    var undoProvider: (() -> UndoManager?)?
    override var undoManager: UndoManager? { undoProvider?() ?? super.undoManager }

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case Selector(("undo:")):
            item.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo == true
        case Selector(("redo:")):
            item.title = undoManager?.redoMenuItemTitle ?? "Redo"
            return undoManager?.canRedo == true
        default:
            return super.validateMenuItem(item)
        }
    }
}

