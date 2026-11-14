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
            ZonesSettings(store: app.zoneStore)
                .tabItem { Label("Zones", systemImage: "rectangle.split.3x1") }
        }
        .frame(minWidth: 700, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
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
                Toggle("Snap to screen edges", isOn: $settings.snapToScreenEdges)
                Toggle("Snap to other windows", isOn: $settings.snapToWindows)
                LabeledContent("Snap distance") {
                    PointsField(value: $settings.snapDistance)
                }
                LabeledContent("Pull-off distance") {
                    PointsField(value: $settings.releaseDistance)
                }
            } footer: {
                Text("Screen edges and other windows use the same snap distance. A snapped edge lets go once pulled past the pull-off distance (never less than the snap distance). Windows that sit flush side by side also line up their tops and bottoms, including when you resize one of them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!settings.snappingEnabled)
        }
        .formStyle(.grouped)
    }
}

/// A 1–30 pt value as a slider plus a text field for typing an exact number.
/// The slider range is fixed (a range that depends on another setting can loop while dragging).
private struct PointsField: View {
    @Binding var value: Double
    static let range: ClosedRange<Double> = 1...30

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: clamped, in: Self.range, step: 1).frame(width: 160)
            TextField("", value: typed, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
            Text("pt").foregroundStyle(.secondary)
        }
    }

    private var clamped: Binding<Double> {
        Binding(get: { min(max(value, Self.range.lowerBound), Self.range.upperBound) },
                set: { value = $0.rounded() })
    }

    private var typed: Binding<Int> {
        Binding(get: { Int(value.rounded()) },
                set: { value = min(max(Double($0), Self.range.lowerBound), Self.range.upperBound) })
    }
}
