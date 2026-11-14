import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import WindowManagerCore

/// Owns the app's long-lived objects and wires them together.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let settings = SettingsStore()
    let permission = AccessibilityPermission()
    let zoneStore = ZoneStore()
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
        menuBar = MenuBarController(app: self)

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
            let w = makeWindow(title: "Settings", content: view)
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        present(settingsWindow!)
    }

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
