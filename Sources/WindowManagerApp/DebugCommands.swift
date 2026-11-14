import AppKit
import WindowManagerCore

enum DebugCommands {
    static func run(_ cmd: String, _ rest: [String]) -> Int32 {
        switch cmd {
        case "--status":
            print("accessibility trusted:", AccessibilityPermission.isTrusted)
            print("skylight available:", SkyLight.isAvailable)
            print("active space:", SkyLight.activeSpace.map(String.init) ?? "?")
        case "--list-windows":
            WindowService().windows(includeNonStandard: rest.contains("--all")).forEach { print($0) }
        case "--list-displays":
            DisplayService.displays.forEach { print($0) }
        case "--list-spaces":
            for d in SkyLight.managedDisplaySpaces {
                let display = d["Display Identifier"] as? String ?? "?"
                let current = (d["Current Space"] as? [String: Any])?["id64"] as? Int ?? 0
                let ids = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["id64"] as? Int }
                print("display \(display) | current \(current) | spaces \(ids)")
            }
        case "--snap":
            // --snap <wid> [distance]: snap a window's current frame as if it had just been moved.
            guard let wid = rest.first.flatMap(UInt32.init), let entry = WindowList.onScreen().first(where: { $0.windowID == wid }),
                  let window = WindowService().window(withID: wid, pid: entry.pid) else {
                print("usage: --snap <window number> [distance]"); return 2
            }
            let engine = SnapEngine(distance: rest.dropFirst().first.flatMap(Double.init).map { CGFloat($0) } ?? 15)
            let others = WindowList.onScreen().filter { $0.windowID != wid }.map(\.frame)
            let screens = DisplayService.displays.map(\.visibleFrame)
            let snapped = engine.snap(entry.frame, operation: .move, others: others, screens: screens)
            print("from", entry.frame, "to", snapped)
            AX.set(window.element, kAXPositionAttribute, point: snapped.origin)
        default:
            print("usage: WindowManagerApp [--status | --list-windows [--all] | --list-displays | --list-spaces | --snap <wid> [distance]]")
            return 2
        }
        return 0
    }
}
