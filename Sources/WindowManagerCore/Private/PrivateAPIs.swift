import ApplicationServices
import CoreGraphics
import Darwin

// Private APIs. Everything here is optional at runtime: SkyLight symbols are looked up with dlsym,
// so if Apple renames one the caller falls back to the public Accessibility path instead of crashing.

/// Maps an AX window element to its CoreGraphics window number. Exported by HIServices; used by
/// every major window manager. The window number is stable for the window's lifetime and across
/// Spaces, so it is the identity we key state on (restore frames now; layouts and tiling later).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// SkyLight (the window server client library). Phase 1 uses it for reliable focus and for
/// reading Spaces; the Spaces / multi-display phase builds on `managedDisplaySpaces`.
public enum SkyLight {
    public typealias ConnectionID = Int32
    public typealias SpaceID = UInt64

    typealias MainConnectionFn = @convention(c) () -> ConnectionID
    typealias GetActiveSpaceFn = @convention(c) (ConnectionID) -> SpaceID
    typealias CopyManagedDisplaySpacesFn = @convention(c) (ConnectionID) -> Unmanaged<CFArray>?
    typealias CopySpacesForWindowsFn = @convention(c) (ConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym<T>(_ name: String, _ h: UnsafeMutableRawPointer? = handle) -> T? {
        guard let h, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static let mainConnectionFn: MainConnectionFn? = sym("SLSMainConnectionID")
    static let getActiveSpaceFn: GetActiveSpaceFn? = sym("SLSGetActiveSpace")
    static let copyManagedDisplaySpacesFn: CopyManagedDisplaySpacesFn? = sym("SLSCopyManagedDisplaySpaces")
    static let copySpacesForWindowsFn: CopySpacesForWindowsFn? = sym("SLSCopySpacesForWindows")
    static let setFrontFn: SetFrontFn? = sym("_SLPSSetFrontProcessWithOptions")
    static let postEventFn: PostEventFn? = sym("SLPSPostEventRecordTo")
    static let getPSNFn: GetPSNFn? = sym("GetProcessForPID", dlopen(nil, RTLD_LAZY))

    /// True when the symbols the app relies on today resolved.
    public static var isAvailable: Bool { mainConnectionFn != nil && setFrontFn != nil }

    public static var connection: ConnectionID? { mainConnectionFn?() }

    public static var activeSpace: SpaceID? {
        guard let c = connection, let f = getActiveSpaceFn else { return nil }
        return f(c)
    }

    /// Raw per-display Space info from the window server: an array of dictionaries with
    /// "Display Identifier", "Current Space" and "Spaces" keys.
    public static var managedDisplaySpaces: [[String: Any]] {
        guard let c = connection, let f = copyManagedDisplaySpacesFn,
              let arr = f(c)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return arr
    }

    /// The Spaces a window is on (more than one when it is assigned to all Spaces).
    public static func spaces(for windowID: CGWindowID) -> [SpaceID] {
        guard let c = connection, let f = copySpacesForWindowsFn else { return [] }
        let mask: Int32 = 0x7 // current, other and fullscreen spaces
        guard let arr = f(c, mask, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        else { return [] }
        return arr.map { $0.uint64Value }
    }

    /// Brings one specific window of `pid` to the front, switching Space if needed. Activating an app
    /// with public API only raises its main window; this targets the exact window.
    public static func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFrontFn, let postEventFn, let getPSNFn else { return false }
        var psn = ProcessSerialNumber()
        guard getPSNFn(pid, &psn) == noErr else { return false }
        guard setFrontFn(&psn, windowID, 0x200 /* kCPSUserGenerated */) == .success else { return false }
        // Two synthetic "make key window" event records, as the window server expects.
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEventFn(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEventFn(&psn, &bytes)
        return true
    }
}
