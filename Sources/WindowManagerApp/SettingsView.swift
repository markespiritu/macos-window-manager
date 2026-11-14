import ServiceManagement
import SwiftUI
import WindowManagerCore

/// Settings window. Later phases add tabs here (Layouts, Displays & Spaces, ...).
struct SettingsView: View {
    let app: AppDelegate
    @ObservedObject var settings: SettingsStore
    @ObservedObject var permission: AccessibilityPermission

    var body: some View {
        TabView {
            GeneralSettings(app: app, permission: permission)
                .tabItem { Label("General", systemImage: "gearshape") }
            SnappingSettings(settings: settings)
                .tabItem { Label("Snapping", systemImage: "rectangle.and.arrow.up.right.and.arrow.down.left") }
        }
        .frame(width: 520, height: 380)
    }
}

private struct GeneralSettings: View {
    let app: AppDelegate
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

private struct SnappingSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Snap windows while moving and resizing", isOn: $settings.snappingEnabled)
            }
            Section {
                LabeledContent("Snap distance") {
                    HStack {
                        Slider(value: $settings.snapDistance, in: 4...50).frame(width: 180)
                        Text("\(Int(settings.snapDistance)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Snap to screen edges", isOn: $settings.snapToScreenEdges)
                Toggle("Snap to other windows", isOn: $settings.snapToWindows)
            } footer: {
                Text("Edges snap flush to screen edges and neighbouring windows. Windows that sit side by side also line up their tops and bottoms, including when you resize one of them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!settings.snappingEnabled)
        }
        .formStyle(.grouped)
    }
}
