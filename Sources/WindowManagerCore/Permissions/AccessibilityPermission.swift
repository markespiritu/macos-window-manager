import AppKit
import ApplicationServices
import Combine

/// Tracks the Accessibility grant. macOS sends no notification when the user flips the switch, so
/// this polls once a second while it is not granted and publishes the change.
@MainActor
public final class AccessibilityPermission: ObservableObject {
    @Published public private(set) var isGranted: Bool
    private var timer: Timer?

    public init() {
        isGranted = AXIsProcessTrusted()
    }

    public nonisolated static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds this app to the Accessibility list (once per install).
    public func requestPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        startPolling()
    }

    public func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startPolling()
    }

    public func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func refresh() {
        let now = AXIsProcessTrusted()
        if now != isGranted { isGranted = now }
        if now { timer?.invalidate(); timer = nil }
    }
}
