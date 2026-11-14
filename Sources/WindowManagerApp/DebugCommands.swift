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
        case "--action":
            // --action <name> [--window <wid>]: run an action on the focused window, or on a window
            // chosen by number (handy from a terminal, whose own window is otherwise the focused one).
            guard let name = rest.first, let action = WindowAction(rawValue: name) else {
                print("actions:", WindowAction.allCases.map(\.rawValue).joined(separator: " "))
                return 2
            }
            let service = WindowService()
            let runner = ActionRunner(windows: service)
            if let i = rest.firstIndex(of: "--window"), i + 1 < rest.count, let wid = UInt32(rest[i + 1]) {
                guard let w = service.windows(includeNonStandard: true).first(where: { $0.windowID == wid }),
                      let f = w.frame else { print("no window \(wid)"); return 1 }
                print(runner.run(action, on: w, current: f))
            } else {
                print(runner.run(action))
            }
        default:
            print("usage: WindowManagerApp [--status | --list-windows [--all] | --list-displays | --list-spaces | --action <name> [--window <wid>]]")
            return 2
        }
        return 0
    }
}
