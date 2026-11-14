import AppKit
import SwiftUI
import WindowManagerCore

/// Settings › Zones: preferences, the layout each display uses, and an editor for that layout.
struct ZonesSettings: View {
    @ObservedObject var store: ZoneStore
    @State private var displays = DisplayService.displays
    @State private var displayID: CGDirectDisplayID = DisplayService.displays.first?.id ?? 0
    @State private var confirmDelete = false
    @State private var confirmReset = false

    private var display: Display? { displays.first { $0.id == displayID } ?? displays.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            preferences
            Divider()
            Group {
            if let display {
                layoutPicker(for: display)
                if let layout = store.layout(for: display) {
                    LayoutEditor(layout: binding(for: layout.id, fallback: layout), screen: display.visibleFrame.size,
                                 canDelete: store.layouts.count > 1, onDelete: { confirmDelete = true })
                        .confirmationDialog("Delete “\(layout.name)”?", isPresented: $confirmDelete) {
                            Button("Delete Layout", role: .destructive) { store.delete(layout.id) }
                        }
                }
            }
            }
            .disabled(!store.enabled)
        }
        .padding(16)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayService.displays
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Drop windows into zones when moving them", isOn: $store.enabled)
            HStack(spacing: 16) {
                Picker("Show zones", selection: $store.activation) {
                    Text("While holding").tag(ZoneActivation.hold)
                    Text("Always, except holding").tag(ZoneActivation.always)
                }
                .fixedSize()
                Picker("Key", selection: $store.modifier) {
                    ForEach(ZoneModifier.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .disabled(!store.enabled)
            HStack(spacing: 16) {
                Picker("Where zones overlap", selection: $store.overlapRule) {
                    Text("Use the smallest zone").tag(ZoneOverlapRule.smallest)
                    Text("Use the top-most zone").tag(ZoneOverlapRule.topmost)
                }
                .fixedSize()
                Toggle("Span zones at borders", isOn: $store.spanAdjacentZones)
                Toggle("Restore size when dragged out", isOn: $store.restoreSizeOnDragOut)
            }
            .disabled(!store.enabled)
            Text("Hold \(store.modifier.spanModifier.label) too to span several zones. ⌃⌥⌘← / → moves the focused window between zones.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func layoutPicker(for display: Display) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if displays.count > 1 {
                    Picker("Display", selection: $displayID) {
                        ForEach(displays) { Text($0.name).tag($0.id) }
                    }
                    .fixedSize()
                } else {
                    Text(display.name).font(.headline)
                }
                Spacer()
                Menu {
                    ForEach(ZoneTemplate.allCases) { t in
                        Menu(t.name) {
                            ForEach(1...8, id: \.self) { n in
                                Button("\(n) zone\(n == 1 ? "" : "s")") {
                                    store.assign(store.add(t.layout(zones: n)).id, to: display)
                                }
                            }
                        }
                    }
                    if let current = store.layout(for: display) {
                        Divider()
                        Button("Duplicate “\(current.name)”") {
                            var copy = current
                            copy.id = UUID()
                            copy.name += " copy"
                            store.assign(store.add(copy).id, to: display)
                        }
                    }
                } label: {
                    Label("New Layout", systemImage: "plus")
                }
                .fixedSize()
                Button("Reset to Defaults…") { confirmReset = true }
                    .confirmationDialog("Reset all zone layouts?", isPresented: $confirmReset) {
                        Button("Reset Layouts", role: .destructive) { store.resetLayouts() }
                    } message: {
                        Text("Your custom layouts are deleted and every display goes back to the first default layout.")
                    }
            }
            // Wraps onto more rows as layouts are added, so none end up out of sight.
            do {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 50 * aspect(display) + 20), spacing: 10, alignment: .top)],
                          alignment: .leading, spacing: 8) {
                    ForEach(Array(store.layouts.enumerated()), id: \.element.id) { i, layout in
                        LayoutThumbnail(layout: layout, index: i,
                                        selected: store.layout(for: display)?.id == layout.id,
                                        aspect: display.visibleFrame.width / max(display.visibleFrame.height, 1))
                            .onTapGesture { store.assign(layout.id, to: display) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func aspect(_ d: Display) -> CGFloat { d.visibleFrame.width / max(d.visibleFrame.height, 1) }

    private func binding(for id: UUID, fallback: ZoneLayout) -> Binding<ZoneLayout> {
        Binding(get: { store.layout(id: id) ?? fallback }, set: { store.update($0) })
    }
}

/// A small picture of a layout, with its name and hotkey number.
private struct LayoutThumbnail: View {
    let layout: ZoneLayout
    let index: Int
    let selected: Bool
    let aspect: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                let area = CGRect(origin: .zero, size: size)
                for r in layout.root.zoneRects(in: area, spacing: 3) {
                    ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(.accentColor.opacity(selected ? 0.55 : 0.3)))
                }
                for f in layout.floating {
                    let r = f.frame(in: area)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(.orange.opacity(0.6)))
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 2), with: .color(.orange), lineWidth: 1)
                }
            }
            .frame(width: 50 * aspect, height: 50)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
            Text(layout.name)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 50 * aspect + 10)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

/// Edits one layout: name, spacing, and the zones themselves.
private struct LayoutEditor: View {
    @Binding var layout: ZoneLayout
    let screen: CGSize
    let canDelete: Bool
    let onDelete: () -> Void
    @State private var hideFree = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $layout.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Button {
                    // Each new zone is offset a little from the last, so they don't hide each other.
                    let step = 0.04 * Double(layout.floating.count % 6)
                    layout.floating.append(FloatingZone(rect: CGRect(x: 0.3 + step, y: 0.3 + step, width: 0.4, height: 0.4)))
                } label: {
                    Label("Add Zone", systemImage: "plus.rectangle.on.rectangle")
                }
                .help("Adds a free zone on top of the others. Drag it to move it, drag its edges to resize it.")
                Toggle("Hide free zones", isOn: $hideFree)
                    .toggleStyle(.button)
                    .disabled(layout.floating.isEmpty)
                    .help("Fades the free zones and lets clicks through, to edit the zones underneath.")
                Spacer()
                Text("Spacing")
                Slider(value: Binding(get: { layout.spacing }, set: { layout.spacing = $0.rounded() }), in: 0...30).frame(width: 120)
                Text("\(Int(layout.spacing)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .disabled(!canDelete)
                    .help("Delete this layout")
            }
            ZoneCanvas(layout: $layout, screen: screen, hideFree: hideFree)
            Text("Right-click a zone to split or remove it, and drag the lines between zones to resize them. Add Zone puts a free zone on top: drag it to move it, drag its edges or corners to resize it (they stick to other zones and to ½ ⅓ ¼ of the screen), and right-click it to change its layer. The lines between split zones stay draggable on top; Hide Free Zones fades the free zones so you can right-click the zones under them. Sizes are in points on this display, and as a share of the screen; double-click a size to type an exact one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The interactive zone editor: a scaled picture of the display.
private struct ZoneCanvas: View {
    @Binding var layout: ZoneLayout
    let screen: CGSize
    let hideFree: Bool
    @State private var hovered: Int?
    /// The free zone being dragged: its rect when the drag started and the edges being moved
    /// (`.all` for a move).
    @State private var floatDrag: (id: UUID, start: CGRect, edges: Edges)?
    /// The zone size being typed in: which zone, which dimension, and the text so far.
    @State private var editing: (zone: Int, axis: SplitAxis)?
    @State private var editText = ""
    @FocusState private var editFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / max(screen.width, 1), geo.size.height / max(screen.height, 1))
            let size = CGSize(width: screen.width * scale, height: screen.height * scale)
            let rect = CGRect(origin: .zero, size: size)
            let spacing = CGFloat(layout.spacing) * scale
            // Split zones, then free zones, in zone order (as on the display).
            let rects = layout.root.zoneRects(in: rect, spacing: spacing) + layout.floating.map { $0.frame(in: rect) }
            let dividers = layout.root.dividers(in: rect, spacing: spacing)
            // The zones' real sizes on the display, in points.
            let real = layout.zoneRects(in: CGRect(origin: .zero, size: screen))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.25))
                    .frame(width: size.width, height: size.height)
                ForEach(0..<min(layout.root.zoneCount, rects.count), id: \.self) { i in
                    zone(i, rects[i], real: real.indices.contains(i) ? real[i] : .zero,
                         covers: Array(rects.dropFirst(layout.root.zoneCount)))
                }
                // Free zones above the split zones, bottom layer first. While "Hide free zones" is
                // on they are faint and ignore the mouse, so the split zones underneath can be edited.
                let base = layout.root.zoneCount
                ForEach(Array(layout.floating.enumerated()), id: \.element.id) { k, f in
                    let i = base + k
                    floating(k, f, index: i, rect: rects.indices.contains(i) ? rects[i] : .zero,
                             real: real.indices.contains(i) ? real[i] : .zero, canvas: rect, all: rects)
                        .opacity(hideFree ? 0.15 : 1)
                        .allowsHitTesting(!hideFree)
                }
                // Dividers on top of everything: they are thin, and this keeps the split zones
                // resizable even where free zones cover them.
                ForEach(dividers) { d in
                    divider(d, spacing: spacing)
                }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "canvas")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 200)
    }

    /// `covers`: the free zones' rects; the label moves to a part of the zone they leave visible.
    private func zone(_ i: Int, _ r: CGRect, real: CGRect, covers: [CGRect]) -> some View {
        let on = hovered == i
        let spot = Self.labelSpot(in: r, avoiding: covers)
        let pw = Int((real.width / max(screen.width, 1) * 100).rounded())
        let ph = Int((real.height / max(screen.height, 1) * 100).rounded())
        return RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor.opacity(on ? 0.5 : 0.3))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: on ? 2 : 1))
            .overlay(alignment: .topLeading) {
                VStack(spacing: 2) {
                    Text("\(i + 1)").font(.system(size: min(max(min(r.width, r.height) / 5, 11), 24), weight: .semibold))
                    if r.width > 70 && r.height > 50 {
                        sizeLine(i, real)
                        Text(verbatim: "\(pw)% × \(ph)%").font(.system(size: 10)).monospacedDigit().opacity(0.8)
                    }
                }
                .foregroundStyle(.white)
                .fixedSize()
                .position(x: spot.x - r.minX, y: spot.y - r.minY)
            }
            .frame(width: max(r.width, 1), height: max(r.height, 1))
            .position(x: r.midX, y: r.midY) // position, not offset: an offset view keeps its layout frame at the top-left, which took clicks meant for other zones
            .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
            .help("Zone \(i + 1): \(Int(real.width)) × \(Int(real.height)) pt (\(pw)% × \(ph)% of the screen)")
            .contextMenu {
                Button("Split Side by Side") { layout.root.split(zone: i, along: .columns) }
                Button("Split Top and Bottom") { layout.root.split(zone: i, along: .rows) }
                Divider()
                Button("Remove Zone") { layout.root.remove(zone: i) }
                    .disabled(layout.root.zoneCount < 2)
            }
    }

    /// "630 × 1488": double-click either number to type a new size. The zones on the other side
    /// of the moved line give or take the difference.
    private func sizeLine(_ i: Int, _ real: CGRect) -> some View {
        HStack(spacing: 3) {
            dimension(i, .columns, Int(real.width))
            Text(verbatim: "×")
            dimension(i, .rows, Int(real.height))
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
    }

    @ViewBuilder
    private func dimension(_ i: Int, _ axis: SplitAxis, _ value: Int) -> some View {
        if let e = editing, e.zone == i, e.axis == axis {
            TextField("", text: $editText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .focused($editFocused)
                .onSubmit { commitEdit() }
                .onExitCommand { editing = nil }
                .onChange(of: editFocused) { _, focused in if !focused { commitEdit() } }
        } else {
            Text(verbatim: "\(value)")
                .padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.001)))
                .onTapGesture(count: 2) {
                    editText = "\(value)"
                    editing = (i, axis)
                    DispatchQueue.main.async { editFocused = true }
                }
                .help(axis == .columns ? "Double-click to type a width" : "Double-click to type a height")
        }
    }

    private func commitEdit() {
        guard let e = editing else { return }
        editing = nil
        guard let v = Double(editText.trimmingCharacters(in: .whitespaces)) else { return }
        var l = layout
        if l.setSize(ofZone: e.zone, along: e.axis, to: CGFloat(v), in: CGRect(origin: .zero, size: screen)) {
            layout = l
        } else {
            NSSound.beep() // e.g. the height of a zone that already fills the screen top to bottom
        }
    }

    private func label(_ i: Int, _ r: CGRect, real: CGRect) -> some View {
        let pw = Int((real.width / max(screen.width, 1) * 100).rounded())
        let ph = Int((real.height / max(screen.height, 1) * 100).rounded())
        return VStack(spacing: 2) {
            Text("\(i + 1)").font(.system(size: min(max(min(r.width, r.height) / 5, 11), 24), weight: .semibold))
            if r.width > 70 && r.height > 50 {
                sizeLine(i, real)
                Text(verbatim: "\(pw)% × \(ph)%").font(.system(size: 10)).monospacedDigit().opacity(0.8)
            }
        }
        .foregroundStyle(.white)
    }

    /// A free zone: drag inside to move it, near an edge or corner to resize it.
    private func floating(_ k: Int, _ f: FloatingZone, index i: Int, rect r: CGRect, real: CGRect,
                          canvas: CGRect, all: [CGRect]) -> some View {
        let active = floatDrag?.id == f.id || hovered == i
        return RoundedRectangle(cornerRadius: 5)
            // See-through, so the zones underneath stay visible (their labels move out of the way).
            .fill(Color.orange.opacity(active ? 0.5 : 0.35))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.orange, lineWidth: active ? 2.5 : 1.5))
            .overlay(label(i, r, real: real))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)).padding(4)
            }
            .frame(width: max(r.width, 1), height: max(r.height, 1))
            .position(x: r.midX, y: r.midY) // position, not offset: an offset view keeps its layout frame at the top-left, which took clicks meant for other zones
            .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
            .onContinuousHover(coordinateSpace: .named("canvas")) { phase in
                guard floatDrag == nil else { return }
                if case .active(let p) = phase { Self.cursor(for: Self.edges(at: p, of: r)).set() } else { NSCursor.arrow.set() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                .onChanged { v in
                    if floatDrag?.id != f.id {
                        let e = Self.edges(at: v.startLocation, of: r)
                        floatDrag = (f.id, r, e.isEmpty ? .all : e)
                    }
                    guard let drag = floatDrag else { return }
                    let moved = Self.drag(drag.start, edges: drag.edges, by: v.translation, in: canvas)
                    let others = all.filter { $0 != r }
                    let xs = [0, 0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75, 1].map { canvas.minX + canvas.width * $0 } + others.flatMap { [$0.minX, $0.maxX] }
                    let ys = [0, 0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75, 1].map { canvas.minY + canvas.height * $0 } + others.flatMap { [$0.minY, $0.maxY] }
                    let snapped = GuideSnap.snap(moved, edges: drag.edges, xs: xs, ys: ys, threshold: 6)
                    guard layout.floating.indices.contains(k) else { return }
                    layout.floating[k].rect = FloatingZone.fraction(of: snapped, in: canvas)
                }
                .onEnded { _ in floatDrag = nil })
            .contextMenu {
                Button("Bring to Front") { let z = layout.floating.remove(at: k); layout.floating.append(z) }
                    .disabled(k == layout.floating.count - 1)
                Button("Bring Forward") { layout.floating.swapAt(k, k + 1) }
                    .disabled(k == layout.floating.count - 1)
                Button("Send Backward") { layout.floating.swapAt(k, k - 1) }
                    .disabled(k == 0)
                Button("Send to Back") { let z = layout.floating.remove(at: k); layout.floating.insert(z, at: 0) }
                    .disabled(k == 0)
                Divider()
                Button("Remove Zone") { layout.floating.remove(at: k) }
            }
    }

    /// Where to put a zone's label: its centre, or else the first of a few other spots inside it
    /// that no free zone covers (falls back to the centre).
    private static func labelSpot(in r: CGRect, avoiding covers: [CGRect]) -> CGPoint {
        let label = CGSize(width: 90, height: 56)
        let spots = [CGPoint(x: r.midX, y: r.midY),
                     CGPoint(x: r.midX, y: r.maxY - label.height / 2 - 8), CGPoint(x: r.midX, y: r.minY + label.height / 2 + 8),
                     CGPoint(x: r.minX + label.width / 2 + 8, y: r.midY), CGPoint(x: r.maxX - label.width / 2 - 8, y: r.midY),
                     CGPoint(x: r.minX + label.width / 2 + 8, y: r.maxY - label.height / 2 - 8),
                     CGPoint(x: r.maxX - label.width / 2 - 8, y: r.maxY - label.height / 2 - 8),
                     CGPoint(x: r.minX + label.width / 2 + 8, y: r.minY + label.height / 2 + 8),
                     CGPoint(x: r.maxX - label.width / 2 - 8, y: r.minY + label.height / 2 + 8)]
        return spots.first { p in
            let box = CGRect(x: p.x - label.width / 2, y: p.y - label.height / 2, width: label.width, height: label.height)
            return r.contains(p) && !covers.contains { $0.intersects(box) }
        } ?? spots[0]
    }

    /// Edges of `r` within grabbing distance of `p`; empty in the middle (a move).
    private static func edges(at p: CGPoint, of r: CGRect) -> Edges {
        let grab = min(10, r.width / 4, r.height / 4)
        var e: Edges = []
        if abs(p.x - r.minX) <= grab { e.insert(.left) } else if abs(p.x - r.maxX) <= grab { e.insert(.right) }
        if abs(p.y - r.minY) <= grab { e.insert(.top) } else if abs(p.y - r.maxY) <= grab { e.insert(.bottom) }
        return e
    }

    private static func cursor(for e: Edges) -> NSCursor {
        if e.isEmpty { return .openHand }
        if e == [.left] || e == [.right] { return .resizeLeftRight }
        if e == [.top] || e == [.bottom] { return .resizeUpDown }
        return .crosshair // corners
    }

    /// The rect after dragging `edges` (or all of it) by `t`, kept inside the canvas and at least
    /// 20 pt each way.
    private static func drag(_ s: CGRect, edges: Edges, by t: CGSize, in c: CGRect) -> CGRect {
        if edges == .all {
            let x = min(max(s.minX + t.width, c.minX), c.maxX - s.width)
            let y = min(max(s.minY + t.height, c.minY), c.maxY - s.height)
            return CGRect(x: x, y: y, width: s.width, height: s.height)
        }
        let minSize: CGFloat = 20
        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        if edges.contains(.left) { minX = min(max(s.minX + t.width, c.minX), maxX - minSize) }
        if edges.contains(.right) { maxX = max(min(s.maxX + t.width, c.maxX), minX + minSize) }
        if edges.contains(.top) { minY = min(max(s.minY + t.height, c.minY), maxY - minSize) }
        if edges.contains(.bottom) { maxY = max(min(s.maxY + t.height, c.maxY), minY + minSize) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func divider(_ d: ZoneNode.Divider, spacing: CGFloat) -> some View {
        // A grab area at least 10 pt thick, centred on the gap.
        let thick: CGFloat = max(10, d.axis == .columns ? d.rect.width : d.rect.height)
        let hit = d.axis == .columns
            ? CGRect(x: d.rect.midX - thick / 2, y: d.rect.minY, width: thick, height: d.rect.height)
            : CGRect(x: d.rect.minX, y: d.rect.midY - thick / 2, width: d.rect.width, height: thick)
        return Rectangle()
            .fill(Color.white.opacity(0.001))
            .overlay(
                Capsule().fill(Color.white.opacity(0.7))
                    .frame(width: d.axis == .columns ? 3 : min(28, hit.width), height: d.axis == .columns ? min(28, hit.height) : 3)
            )
            .frame(width: hit.width, height: hit.height)
            .position(x: hit.midX, y: hit.midY)
            .onHover { inside in
                if inside { (d.axis == .columns ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas")).onChanged { v in
                layout.root.move(d, to: d.axis == .columns ? v.location.x : v.location.y, spacing: spacing)
            })
    }
}
