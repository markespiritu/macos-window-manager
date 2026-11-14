import AppKit

/// Draws the zones over each display while a window is being dragged into them. One borderless,
/// click-through panel per display, above normal windows, on every Space.
@MainActor
public final class ZoneOverlay {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]

    public init() {}

    /// Shows the zones of each display (AX-space rects) and highlights `selected` on `activeDisplay`.
    public func show(_ zones: [(display: Display, rects: [CGRect])], active activeDisplay: CGDirectDisplayID?, selected: Set<Int>) {
        let ids = Set(zones.map(\.display.id))
        for (id, p) in panels where !ids.contains(id) { p.orderOut(nil); panels[id] = nil }
        for (display, rects) in zones {
            let panel = panels[display.id] ?? makePanel()
            panels[display.id] = panel
            // Panel frames are AppKit space; the display frame comes in AX space.
            let appKitFrame = ScreenCoordinates.flip(display.frame, primaryHeight: DisplayService.primaryHeight)
            if panel.frame != appKitFrame { panel.setFrame(appKitFrame, display: false) }
            let view = panel.contentView as! ZoneOverlayView
            view.update(origin: display.frame.origin, rects: rects,
                        selected: display.id == activeDisplay ? selected : [])
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    public func hide() {
        panels.values.forEach { $0.orderOut(nil) }
    }

    /// Shows the zones briefly, e.g. after switching layouts with a hotkey.
    public func flash(_ zones: [(display: Display, rects: [CGRect])], seconds: Double = 0.6) {
        show(zones, active: nil, selected: [])
        let snapshot = panels.values.map { ObjectIdentifier($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            for p in self.panels.values where snapshot.contains(ObjectIdentifier(p)) { p.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = ZoneOverlayView()
        return p
    }
}

final class ZoneOverlayView: NSView {
    private var origin: CGPoint = .zero
    private var rects: [CGRect] = []
    private var selected: Set<Int> = []

    override var isFlipped: Bool { true } // AX space is y-down, so local coordinates are just offsets

    func update(origin: CGPoint, rects: [CGRect], selected: Set<Int>) {
        guard origin != self.origin || rects != self.rects || selected != self.selected else { return }
        self.origin = origin
        self.rects = rects
        self.selected = selected
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        for (i, r) in rects.enumerated() {
            let local = r.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: local, xRadius: 10, yRadius: 10)
            let on = selected.contains(i)
            (on ? accent.withAlphaComponent(0.45) : NSColor.black.withAlphaComponent(0.18)).setFill()
            path.fill()
            (on ? accent : NSColor.white.withAlphaComponent(0.55)).setStroke()
            path.lineWidth = on ? 3 : 1.5
            path.stroke()

            let label = "\(i + 1)" as NSString
            let size = min(max(min(local.width, local.height) / 5, 18), 64)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(on ? 0.95 : 0.7),
            ]
            let ts = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: local.midX - ts.width / 2, y: local.midY - ts.height / 2), withAttributes: attrs)
        }
    }
}
