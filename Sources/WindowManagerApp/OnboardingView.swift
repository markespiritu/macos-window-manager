import SwiftUI
import WindowManagerCore

/// First-run screen. Window management needs the Accessibility permission, and macOS only lets the
/// user grant it in System Settings, so this explains why and watches for the switch to flip.
struct OnboardingView: View {
    @ObservedObject var permission: AccessibilityPermission

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Window Manager needs Accessibility access")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("macOS only lets apps move and resize other apps' windows with this permission. Window Manager does not read the contents of your windows or what you type.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Click Open System Settings.")
                step(2, "Turn on Window Manager in Privacy & Security › Accessibility.")
                step(3, "Come back here. This window closes on its own.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Label(permission.isGranted ? "Access granted" : "Waiting for access…",
                      systemImage: permission.isGranted ? "checkmark.circle.fill" : "clock")
                    .foregroundStyle(permission.isGranted ? .green : .secondary)
                Spacer()
                Button("Open System Settings") {
                    permission.requestPrompt()
                    permission.openSystemSettings()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(permission.isGranted)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { permission.startPolling() }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.callout.monospacedDigit().bold()).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
