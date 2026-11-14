import ServiceManagement
import SwiftUI
import WindowManagerCore

/// Settings window. Each phase adds a tab here (Snapping, Layouts, Displays & Spaces, Tiling).
struct SettingsView: View {
    let app: AppDelegate
    @ObservedObject var settings: SettingsStore
    @ObservedObject var permission: AccessibilityPermission

    var body: some View {
        TabView {
            GeneralSettings(app: app, settings: settings, permission: permission)
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettings(app: app, settings: settings)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralSettings: View {
    let app: AppDelegate
    @ObservedObject var settings: SettingsStore
    @ObservedObject var permission: AccessibilityPermission
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Windows") {
                LabeledContent("Gap between windows") {
                    HStack {
                        Slider(value: $settings.gap, in: 0...40, step: 2).frame(width: 180)
                        Text("\(Int(settings.gap)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if permission.isGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { app.showOnboarding() }
                    }
                }
                LabeledContent("Private window server APIs") {
                    Text(SkyLight.isAvailable ? "Available" : "Unavailable (using public APIs)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct ShortcutSettings: View {
    @ObservedObject var app: AppDelegate
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                ForEach(WindowAction.allCases) { action in
                    LabeledContent {
                        HStack(spacing: 6) {
                            if app.conflicts.contains(action.rawValue) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("Another app is already using this shortcut.")
                            }
                            ShortcutRecorder(combo: binding(for: action), hotkeys: app.hotkeys) { combo in
                                settings.action(using: combo, except: action).map { "Used by \($0.title)" }
                            }
                        }
                    } label: {
                        Label(action.title, systemImage: action.symbolName)
                    }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { settings.resetBindings() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for action: WindowAction) -> Binding<KeyCombo?> {
        Binding(get: { settings.bindings[action] },
                set: { settings.bindings[action] = $0 })
    }
}
