import AppKit
import Carbon.HIToolbox
import SwiftUI
import WindowManagerCore

/// Click to record a shortcut. Esc cancels, Delete clears. Global hotkeys are suspended while
/// recording so an existing combination reaches the recorder instead of firing its action.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    let hotkeys: HotkeyCenter
    /// Returns a message when the combination is already taken, which rejects it.
    var conflict: (KeyCombo) -> String? = { _ in nil }

    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Text(label)
                    .frame(minWidth: 110)
                    .foregroundStyle(recording ? Color.accentColor : (combo == nil ? .secondary : .primary))
            }
            .help(message ?? "Click, then press the new shortcut. Esc cancels, Delete clears.")
            if combo != nil && !recording {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording { return message ?? "Type shortcut…" }
        return combo?.description ?? "None"
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        message = nil
        hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { hotkeys.resume() }
        recording = false
    }

    private func handle(_ event: NSEvent) {
        let code = UInt32(event.keyCode)
        let mods = Self.carbonModifiers(event.modifierFlags)
        if mods == 0 && code == UInt32(kVK_Escape) { stop(); return }
        if mods == 0 && (code == UInt32(kVK_Delete) || code == UInt32(kVK_ForwardDelete)) {
            combo = nil; stop(); return
        }
        let candidate = KeyCombo(keyCode: code, modifiers: mods)
        guard candidate.isValidHotkey else { message = "Add ⌃, ⌥ or ⌘"; return }
        if let clash = conflict(candidate) { message = clash; return }
        combo = candidate
        stop()
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }
}
