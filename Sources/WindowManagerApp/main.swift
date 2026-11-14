import AppKit
import WindowManagerCore

// Debug commands run without starting the menu bar app, e.g.
//   "build/Window Manager.app/Contents/MacOS/WindowManagerApp" --list-windows
// They use whatever Accessibility grant the calling process (your terminal) has.
let args = CommandLine.arguments
if let cmd = args.dropFirst().first, cmd.hasPrefix("--") {
    exit(DebugCommands.run(cmd, Array(args.dropFirst(2))))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
