import AppKit

/// Runs a `WindowAction` against the focused window.
public final class ActionRunner {
    public enum Outcome: Equatable {
        case applied(CGRect)
        case noWindow
        case notResizable
        case nothingToRestore
        case failed
    }

    private let windows: WindowControlling
    private let displays: () -> [Display]
    /// Frames from before the last action, keyed by window number, so `.restore` can undo.
    /// The save/restore phase will persist window positions separately; this is in-memory only.
    private var previousFrames: [CGWindowID: CGRect] = [:]

    public var gap: CGFloat = 0

    public init(windows: WindowControlling = WindowService(),
                displays: @escaping () -> [Display] = { DisplayService.displays }) {
        self.windows = windows
        self.displays = displays
    }

    @discardableResult
    public func run(_ action: WindowAction) -> Outcome {
        guard let window = windows.focusedWindow(), let current = window.frame else { return .noWindow }
        return run(action, on: window, current: current)
    }

    @discardableResult
    public func run(_ action: WindowAction, on window: Window, current: CGRect) -> Outcome {
        let target: CGRect
        if action == .restore {
            guard let wid = window.windowID, let saved = previousFrames[wid] else { return .nothingToRestore }
            target = saved
            previousFrames[wid] = nil
        } else {
            guard let display = DisplayService.display(for: current, in: displays()),
                  let f = LayoutMath.frame(for: action, visibleFrame: display.visibleFrame,
                                           current: current, gap: gap) else { return .failed }
            if action != .center && !window.isResizable { return .notResizable }
            target = f
            // Keep the frame from before the first of a run of actions, so restore goes all the way
            // back rather than to the previous half.
            if let wid = window.windowID, previousFrames[wid] == nil { previousFrames[wid] = current }
        }
        return windows.setFrame(target, of: window) ? .applied(target) : .failed
    }
}
