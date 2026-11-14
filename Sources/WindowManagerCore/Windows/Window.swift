import AppKit
import ApplicationServices

/// A top-level window of a running app, reached through the Accessibility API.
/// This is a lightweight handle: reading `frame` or `title` asks the app each time.
public struct Window: CustomStringConvertible {
    public let element: AXUIElement
    public let pid: pid_t
    /// CoreGraphics window number, or nil when the private lookup fails. Prefer it as identity.
    public let windowID: CGWindowID?

    public init(element: AXUIElement, pid: pid_t) {
        self.element = element
        self.pid = pid
        var wid: CGWindowID = 0
        self.windowID = _AXUIElementGetWindow(element, &wid) == .success && wid != 0 ? wid : nil
    }

    public var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    public var appName: String { app?.localizedName ?? "pid \(pid)" }
    public var bundleID: String? { app?.bundleIdentifier }

    public var title: String { AX.attribute(element, kAXTitleAttribute) ?? "" }
    public var role: String? { AX.attribute(element, kAXRoleAttribute) }
    public var subrole: String? { AX.attribute(element, kAXSubroleAttribute) }
    public var isMinimized: Bool { AX.attribute(element, kAXMinimizedAttribute) ?? false }
    public var isFullscreen: Bool { AX.attribute(element, "AXFullScreen") ?? false }

    /// Standard windows are the ones a window manager should arrange (not sheets, palettes, popovers).
    public var isStandard: Bool { subrole == (kAXStandardWindowSubrole as String) }

    public var isResizable: Bool { AX.isSettable(element, kAXSizeAttribute) }
    public var isMovable: Bool { AX.isSettable(element, kAXPositionAttribute) }

    /// Frame in AX space (top-left origin of the primary display, y down).
    public var frame: CGRect? {
        guard let p = AX.point(element, kAXPositionAttribute), let s = AX.size(element, kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Same window, compared by window number when both have one, else by AX element.
    public func isSame(as other: Window) -> Bool {
        if let a = windowID, let b = other.windowID { return a == b }
        return CFEqual(element, other.element)
    }

    public var description: String {
        let f = frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "?"
        return "\(appName) | \(title) | wid \(windowID.map(String.init) ?? "?") | \(f)"
    }
}

/// Thin typed wrappers over the AX C API.
public enum AX {
    /// Calls into a hung app block the caller for this long at most (default is ~6s).
    public static let messagingTimeout: Float = 1.0

    public static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    public static func point(_ el: AXUIElement, _ name: String) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    public static func size(_ el: AXUIElement, _ name: String) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    @discardableResult
    public static func set(_ el: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, name as CFString, value) == .success
    }

    @discardableResult
    public static func set(_ el: AXUIElement, _ name: String, point: CGPoint) -> Bool {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return set(el, name, v)
    }

    @discardableResult
    public static func set(_ el: AXUIElement, _ name: String, size: CGSize) -> Bool {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return set(el, name, v)
    }

    public static func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &settable) == .success && settable.boolValue
    }

    public static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }
}
