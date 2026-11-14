import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys via Carbon RegisterEventHotKey. That API needs no Input Monitoring
/// permission and no event tap, and it is still the supported way to register global shortcuts.
///
/// Bindings are keyed by a string id so any feature can own hotkeys: window actions use the
/// action's raw value today; layouts and tiling commands can use their own ids later.
public final class HotkeyCenter {
    public struct Binding {
        public let id: String
        public let combo: KeyCombo
        public let handler: () -> Void
        public init(id: String, combo: KeyCombo, handler: @escaping () -> Void) {
            self.id = id; self.combo = combo; self.handler = handler
        }
    }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var bindings: [Binding] = []
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private static let signature = OSType(0x574D4752) // 'WMGR'

    public private(set) var isSuspended = false

    public init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            guard let event, let ctx else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(ctx).takeUnretainedValue()
            guard hk.signature == HotkeyCenter.signature, let h = center.handlers[hk.id] else {
                return OSStatus(eventNotHandledErr)
            }
            h()
            return noErr
        }, 1, &spec, me, &eventHandler)
    }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Replaces every registered hotkey. Returns the ids whose combination could not be registered
    /// (usually because another app or the system already owns it).
    @discardableResult
    public func setBindings(_ new: [Binding]) -> [String] {
        bindings = new
        return isSuspended ? [] : registerAll()
    }

    /// Temporarily releases all hotkeys, e.g. while the settings window records a new shortcut,
    /// so pressing an existing combination reaches the recorder instead of firing the action.
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        unregisterAll()
    }

    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        registerAll()
    }

    @discardableResult
    private func registerAll() -> [String] {
        unregisterAll()
        var failed: [String] = []
        for b in bindings {
            let id = nextID; nextID &+= 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(b.combo.keyCode, b.combo.modifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[id] = ref
                handlers[id] = b.handler
            } else {
                failed.append(b.id)
            }
        }
        return failed
    }

    private func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }
}
