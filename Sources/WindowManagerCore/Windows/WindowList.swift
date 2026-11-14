import AppKit
import CoreGraphics

/// Fast window geometry from the window server (CGWindowList), with no calls into other apps.
/// Bounds are already in AX space (top-left origin of the primary display, y down).
public enum WindowList {
    public struct Entry: Equatable {
        public let windowID: CGWindowID
        public let pid: pid_t
        public let frame: CGRect
        public let owner: String
    }

    /// Normal (layer 0) on-screen windows of other apps, front to back.
    public static func onScreen(excludingPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> [Entry] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap(entry).filter { $0.pid != excludingPID && $0.frame.width > 40 && $0.frame.height > 40 }
    }

    /// The frontmost normal window under a point (AX space). `margin` widens each window, because
    /// the resize handles of macOS windows reach a few points outside the frame.
    public static func window(at point: CGPoint, margin: CGFloat = 0) -> Entry? {
        onScreen().first { $0.frame.insetBy(dx: -margin, dy: -margin).contains(point) }
    }

    /// Current frame of one window, straight from the window server.
    public static func frame(of windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let info = list.first, let b = info[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: b as CFDictionary)
    }

    private static func entry(_ info: [String: Any]) -> Entry? {
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              let wid = info[kCGWindowNumber as String] as? CGWindowID,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let b = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: b as CFDictionary)
        else { return nil }
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
        guard alpha > 0 else { return nil }
        return Entry(windowID: wid, pid: pid, frame: frame, owner: info[kCGWindowOwnerName as String] as? String ?? "")
    }
}

public extension WindowService {
    /// The AX element for a window number, by asking its app for its windows.
    func window(withID wid: CGWindowID, pid: pid_t) -> Window? {
        let els: [AXUIElement] = AX.attribute(AX.application(pid), kAXWindowsAttribute) ?? []
        return els.lazy.map { Window(element: $0, pid: pid) }.first { $0.windowID == wid }
    }
}
