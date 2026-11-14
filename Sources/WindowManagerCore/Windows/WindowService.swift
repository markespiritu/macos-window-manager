import AppKit
import ApplicationServices

/// What the rest of the app needs from the window system. Actions, and later snapping, layouts and
/// tiling, depend on this protocol, so they can be tested with a fake and so a SkyLight-backed
/// implementation can replace pieces without touching callers.
public protocol WindowControlling {
    func focusedWindow() -> Window?
    func windows(includeNonStandard: Bool) -> [Window]
    @discardableResult func setFrame(_ frame: CGRect, of window: Window) -> Bool
    @discardableResult func focus(_ window: Window) -> Bool
}

/// The Accessibility-backed implementation.
public final class WindowService: WindowControlling {
    public init() {}

    /// The key window of the frontmost app.
    public func focusedWindow() -> Window? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AX.application(front.processIdentifier)
        if let el: AXUIElement = AX.attribute(app, kAXFocusedWindowAttribute) {
            return Window(element: el, pid: front.processIdentifier)
        }
        if let el: AXUIElement = AX.attribute(app, kAXMainWindowAttribute) {
            return Window(element: el, pid: front.processIdentifier)
        }
        return nil
    }

    /// Windows of regular (Dock) apps on the current Space, in each app's AX order.
    /// Other-Space windows need the remote-token path; that arrives with the Spaces phase.
    public func windows(includeNonStandard: Bool = false) -> [Window] {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
            .flatMap { app -> [Window] in
                let pid = app.processIdentifier
                let els: [AXUIElement] = AX.attribute(AX.application(pid), kAXWindowsAttribute) ?? []
                return els.map { Window(element: $0, pid: pid) }
            }
            .filter { includeNonStandard || $0.isStandard }
    }

    /// Moves and resizes a window. Returns true if the window ended up close to the requested frame
    /// (apps may enforce a minimum size or snap to a character grid, as terminals do).
    @discardableResult
    public func setFrame(_ frame: CGRect, of window: Window) -> Bool {
        let app = AX.application(window.pid)
        // Apps with AXEnhancedUserInterface on (set by VoiceOver or some assistive tools, common in
        // Chromium/Electron) animate every AX resize and drop intermediate steps. Turn it off for the
        // duration of the move.
        let enhanced: Bool = AX.attribute(app, "AXEnhancedUserInterface") ?? false
        if enhanced { AX.set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced { AX.set(app, "AXEnhancedUserInterface", kCFBooleanTrue) } }

        // Size, position, size: the first resize lets the window fit at the new position (e.g. when
        // moving to a smaller display); the second fixes a size the app clamped at the old position.
        AX.set(window.element, kAXSizeAttribute, size: frame.size)
        AX.set(window.element, kAXPositionAttribute, point: frame.origin)
        AX.set(window.element, kAXSizeAttribute, size: frame.size)

        guard let actual = window.frame else { return false }
        return abs(actual.minX - frame.minX) < 2 && abs(actual.minY - frame.minY) < 2
    }

    /// Raises and focuses one specific window, preferring the SkyLight path (exact window, works
    /// across Spaces) and falling back to public API.
    @discardableResult
    public func focus(_ window: Window) -> Bool {
        if let wid = window.windowID, SkyLight.focus(pid: window.pid, windowID: wid) {
            AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            return true
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AX.set(window.element, kAXMainAttribute, kCFBooleanTrue)
        return window.app?.activate() ?? false
    }
}
