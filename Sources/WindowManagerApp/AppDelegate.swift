import AppKit
import Combine
import SwiftUI
import WindowManagerCore

/// Owns the app's long-lived objects and wires them together.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let settings = SettingsStore()
    let permission = AccessibilityPermission()
    let hotkeys = HotkeyCenter()
    let runner = ActionRunner()

    private var menuBar: MenuBarController!
    private var onboarding: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    /// Action ids whose shortcut another app already owns; shown in settings.
    @Published private(set) var conflicts: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(app: self)

        settings.$bindings
            .sink { [weak self] b in self?.registerHotkeys(b) }
            .store(in: &cancellables)
        settings.$gap
            .sink { [weak self] g in self?.runner.gap = CGFloat(g) }
            .store(in: &cancellables)
        permission.$isGranted
            .removeDuplicates()
            .sink { [weak self] granted in
                self?.menuBar.refresh()
                if granted { self?.onboarding?.close() }
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

    func perform(_ action: WindowAction) {
        guard permission.isGranted else { showOnboarding(); return }
        if case .applied = runner.run(action) { return }
        NSSound.beep()
    }

    private func registerHotkeys(_ bindings: [WindowAction: KeyCombo]) {
        let list = bindings.map { action, combo in
            HotkeyCenter.Binding(id: action.rawValue, combo: combo) { [weak self] in
                Task { @MainActor in self?.perform(action) }
            }
        }
        conflicts = Set(hotkeys.setBindings(list))
        menuBar?.refresh(bindings: bindings)
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
