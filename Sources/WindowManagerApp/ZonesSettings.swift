import AppKit
import SwiftUI
import WindowManagerCore

/// Settings › Zones: preferences, the layout each display uses, and an editor for that layout.
struct ZonesSettings: View {
    @ObservedObject var store: ZoneStore
    /// Undo / redo for zone edits and layout list changes (⌘Z, ⇧⌘Z and the Edit menu).
    let history: ZoneEditHistory
    @State private var displays = DisplayService.displays
    @State private var displayID: CGDirectDisplayID = DisplayService.displays.first?.id ?? 0
    /// The layout a Delete is waiting on confirmation for.
    @State private var layoutToDelete: ZoneLayout?
    @State private var confirmReset = false
    /// The zone selected in the editor. Selecting a layout clears it, so Delete then applies to
    /// the layout.
    @State private var selectedZone: Int?
    @FocusState private var layoutsFocused: Bool

    private var display: Display? { displays.first { $0.id == displayID } ?? displays.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            preferences
            Divider()
            Group {
            if let display {
                layoutPicker(for: display)
                if let layout = store.layout(for: display) {
                    LayoutEditor(layout: binding(for: layout.id, fallback: layout), history: history, screen: display.visibleFrame.size,
                                 selected: $selectedZone,
                                 canDelete: store.layouts.count > 1, onDelete: { layoutToDelete = layout })
                }
            }
            }
            .disabled(!store.enabled)
        }
        .padding(16)
        .confirmationDialog("Delete “\(layoutToDelete?.name ?? "")”?",
                            isPresented: Binding(get: { layoutToDelete != nil }, set: { if !$0 { layoutToDelete = nil } }),
                            presenting: layoutToDelete) { layout in
            Button("Delete Layout", role: .destructive) { deleteLayout(layout.id) }
        } message: { _ in
            Text("Displays using it switch to the first layout. ⌘Z brings it back.")
        }
        .onAppear {
            history.isEditorVisible = true
            // Undoing an edit to a layout that isn't on screen shows it first.
            history.show = { [store] id in
                guard let d = display, store.layout(for: d)?.id != id else { return }
                selectedZone = nil
                store.assign(id, to: d)
            }
        }
        .onDisappear { history.isEditorVisible = false } // another Settings tab: ⌘Z leaves zones alone
        .onChange(of: displayID) { selectedZone = nil }
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
                    Text("Use the top-most zone (highest number)").tag(ZoneOverlapRule.topmost)
                    Text("Use the smallest zone").tag(ZoneOverlapRule.smallest)
                    Text("Use the zone whose centre is closest").tag(ZoneOverlapRule.closestCenter)
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
                                    selectedZone = nil
                                    history.addLayout(t.layout(zones: n), showOn: ZoneStore.key(for: display))
                                }
                            }
                        }
                    }
                    if let current = store.layout(for: display) {
                        Divider()
                        Button("Duplicate “\(current.name)”") { duplicate(current, on: display) }
                    }
                } label: {
                    Label("New Layout", systemImage: "plus")
                }
                .fixedSize()
                Button("Reset to Defaults…") { confirmReset = true }
                    .confirmationDialog("Reset all zone layouts?", isPresented: $confirmReset) {
                        Button("Reset Layouts", role: .destructive) {
                            selectedZone = nil
                            history.resetLayouts()
                        }
                    } message: {
                        Text("Your custom layouts are deleted and every display goes back to the first default layout. ⌘Z brings them back.")
                    }
            }
            // Wraps onto more rows as layouts are added, so none end up out of sight.
            do {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 50 * aspect(display) + 20), spacing: 10, alignment: .top)],
                          alignment: .leading, spacing: 8) {
                    ForEach(Array(store.layouts.enumerated()), id: \.element.id) { i, layout in
                        LayoutThumbnail(layout: layout, index: i,
                                        selected: store.layout(for: display)?.id == layout.id,
                                        focused: layoutsFocused,
                                        aspect: display.visibleFrame.width / max(display.visibleFrame.height, 1))
                            .onTapGesture { selectLayout(layout.id, on: display) }
                            .contextMenu {
                                Button("Duplicate") { duplicate(layout, on: display) }
                                Divider()
                                Button("Delete “\(layout.name)”…") { layoutToDelete = layout }
                                    .disabled(store.layouts.count < 2)
                            }
                    }
                }
                .padding(.vertical, 2)
                // Click a layout to select it (the zone selection is cleared): Delete then deletes
                // the layout, after a confirmation.
                .focusable()
                .focusEffectDisabled()
                .focused($layoutsFocused)
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                    guard store.layouts.count > 1, let current = store.layout(for: display) else { return .ignored }
                    layoutToDelete = current
                    return .handled
                }
            }
        }
    }

    private func selectLayout(_ id: UUID, on display: Display) {
        selectedZone = nil
        store.assign(id, to: display)
        layoutsFocused = true
    }

    private func duplicate(_ layout: ZoneLayout, on display: Display) {
        var copy = layout
        copy.id = UUID()
        copy.name += " copy"
        selectedZone = nil
        history.addLayout(copy, showOn: ZoneStore.key(for: display), "Duplicate Layout")
    }

    private func deleteLayout(_ id: UUID) {
        selectedZone = nil
        history.deleteLayout(id)
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
    /// The layout list has keyboard focus (Delete deletes the selected layout).
    let focused: Bool
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
        // White while the list has focus (like a selected zone): this is the layout Delete deletes.
        .background(RoundedRectangle(cornerRadius: 7).fill(selected && focused ? Color.accentColor.opacity(0.2) : .clear))
        .background(RoundedRectangle(cornerRadius: 7).stroke(selected ? (focused ? Color.white : Color.accentColor) : .clear,
                                                            lineWidth: selected && focused ? 3 : 2))
        .contentShape(Rectangle())
    }
}

/// Edits one layout: name, spacing, and the zones themselves.
private struct LayoutEditor: View {
    @Binding var layout: ZoneLayout
    let history: ZoneEditHistory
    let screen: CGSize
    @Binding var selected: Int?
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
                    history.edit(layout.id, "Add Zone") {
                        $0.floating.append(FloatingZone(rect: CGRect(x: 0.3 + step, y: 0.3 + step, width: 0.4, height: 0.4)))
                    }
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
                Slider(value: Binding(get: { layout.spacing }, set: { v in
                    // One undo step per slider drag (or run of changes close together).
                    history.edit(layout.id, "Change Spacing", coalesce: "spacing", within: 1) { $0.spacing = v.rounded() }
                }), in: 0...30).frame(width: 120)
                Text("\(Int(layout.spacing)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .disabled(!canDelete)
                    .help("Delete this layout")
            }
            ZoneCanvas(layout: layout, history: history, screen: screen, hideFree: hideFree, selected: $selected)
            Text("Click a layout above to select it: Delete deletes it (after asking), and right-click it to duplicate or delete it. Right-click a zone to split or remove it, and drag the lines between zones to resize them. Add Zone puts a free zone on top: drag it to move it, drag its edges or corners to resize it (they stick to other zones and to ½ ⅓ ¼ of the screen), and right-click it to change its layer. The lines between split zones stay draggable on top; Hide Free Zones fades the free zones so you can right-click the zones under them. Sizes are in points on this display, and as a share of the screen; double-click a size to type an exact one. Click a zone to select it: Delete removes it (after asking), arrows move a free zone (⇧ for 10 pt), ⌥ arrows resize it, and arrows resize a split zone. ⌘Z undoes, ⇧⌘Z redoes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The interactive zone editor: a scaled picture of the display.
private struct ZoneCanvas: View {
    let layout: ZoneLayout
    let history: ZoneEditHistory
    let screen: CGSize
    let hideFree: Bool
    /// The zone a click selected; Delete removes it, after a confirmation.
    @Binding var selected: Int?
    @State private var hovered: Int?
    @State private var zoneToDelete: Int?
    @FocusState private var canvasFocused: Bool
    /// The free zone being dragged: its rect when the drag started and the edges being moved
    /// (`.all` for a move).
    @State private var floatDrag: (id: UUID, start: CGRect, edges: Edges)?
    /// The zone size being typed in: which zone, which dimension, and the text so far.
    @State private var editing: (zone: Int, axis: SplitAxis)?
    @State private var editText = ""
    @FocusState private var editFocused: Bool
    /// Coalescing key for the drag in progress (free zone or divider): the whole drag is one
    /// undo step. Renewed when a drag ends.
    @State private var dragKey = UUID().uuidString

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
                // Measuring rulers for the zone being dragged, else the one under the mouse.
                if let a = activeZone, real.indices.contains(a) {
                    Rulers(measures: ZoneRuler.measures(for: a, in: real, screen: CGRect(origin: .zero, size: screen)), scale: scale)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "canvas")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 200)
        // Keyboard: Delete / Forward Delete removes the selected zone, Esc deselects.
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard editing == nil, let i = selected else { return .ignored }
            // The last split zone can't go (a free zone always can).
            if i < layout.root.zoneCount && layout.root.zoneCount < 2 { NSSound.beep(); return .handled }
            zoneToDelete = i
            return .handled
        }
        .confirmationDialog("Delete zone \((zoneToDelete ?? 0) + 1)?",
                            isPresented: Binding(get: { zoneToDelete != nil }, set: { if !$0 { zoneToDelete = nil } }),
                            presenting: zoneToDelete) { i in
            Button("Delete Zone", role: .destructive) { removeZone(i) }
        } message: { _ in
            Text("⌘Z brings it back. To delete the whole layout, click it in the list above first.")
        }
        .onKeyPress(.escape) { selected = nil; return .handled }
        // Arrows: move a free zone 1 pt (⇧ 10 pt). ⌥ arrows, and plain arrows on a split zone,
        // resize instead: → / ↓ grow the width / height, ← / ↑ shrink it.
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard editing == nil, let i = selected else { return .ignored }
            nudge(i, key: press.key, step: press.modifiers.contains(.shift) ? 10 : 1,
                  resize: press.modifiers.contains(.option))
            return .handled
        }
        .onChange(of: layout.zoneCount) { _, n in if let s = selected, s >= n { selected = nil } }
    }

    /// `covers`: the free zones' rects; the label moves to a part of the zone they leave visible.
    private func zone(_ i: Int, _ r: CGRect, real: CGRect, covers: [CGRect]) -> some View {
        let on = hovered == i
        let spot = Self.labelSpot(in: r, avoiding: covers)
        let pw = Int((real.width / max(screen.width, 1) * 100).rounded())
        let ph = Int((real.height / max(screen.height, 1) * 100).rounded())
        return RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor.opacity(on ? 0.5 : 0.3))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected == i ? Color.white : Color.accentColor, lineWidth: selected == i ? 3 : (on ? 2 : 1)))

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
            .contentShape(Rectangle())
            .onTapGesture { select(i) } // after the label overlay, so a click on the label selects too
            .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
            .help("Zone \(i + 1): \(Int(real.width)) × \(Int(real.height)) pt (\(pw)% × \(ph)% of the screen)")
            .contextMenu {
                Button("Split Side by Side") { edit("Split Zone") { $0.root.split(zone: i, along: .columns) } }
                Button("Split Top and Bottom") { edit("Split Zone") { $0.root.split(zone: i, along: .rows) } }
                Divider()
                Button("Remove Zone") { removeZone(i) }
                    .disabled(layout.root.zoneCount < 2)
            }
            .position(x: r.midX, y: r.midY) // last: modifiers after .position would cover the whole canvas
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
            commit(l, e.axis == .columns ? "Change Zone Width" : "Change Zone Height")
        } else {
            NSSound.beep() // e.g. the height of a zone that already fills the screen top to bottom
        }
    }

    /// Saves an edited layout as one undo step (or part of the step `coalesce` names).
    private func commit(_ l: ZoneLayout, _ name: String, coalesce: String? = nil, within: TimeInterval? = nil) {
        history.commit(l, name, coalesce: coalesce, within: within)
    }

    private func edit(_ name: String, _ change: (inout ZoneLayout) -> Void) {
        history.edit(layout.id, name, change)
    }

    private func select(_ i: Int) {
        selected = i
        canvasFocused = true
    }

    private func nudge(_ i: Int, key: KeyEquivalent, step: CGFloat, resize: Bool) {
        let frame = CGRect(origin: .zero, size: screen)
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch key {
        case .leftArrow: dx = -step
        case .rightArrow: dx = step
        case .upArrow: dy = -step
        default: dy = step
        }
        var l = layout
        let changed: Bool
        let resizing = resize || i < l.root.zoneCount
        if resizing {
            let rects = l.zoneRects(in: frame)
            guard rects.indices.contains(i) else { return }
            changed = dx != 0
                ? l.setSize(ofZone: i, along: .columns, to: rects[i].width + dx, in: frame)
                : l.setSize(ofZone: i, along: .rows, to: rects[i].height + dy, in: frame)
        } else {
            changed = l.move(zone: i, dx: dx, dy: dy, in: frame)
        }
        // A run of presses on one zone (each within a second of the last) is one undo step.
        if changed {
            commit(l, resizing ? "Resize Zone" : "Move Zone", coalesce: "nudge-\(i)-\(resizing)", within: 1)
        } else {
            NSSound.beep()
        }
    }

    /// Removes a split zone (not the last one; its neighbour takes the space) or a free zone.
    private func removeZone(_ i: Int) {
        let base = layout.root.zoneCount
        if i >= base {
            guard layout.floating.indices.contains(i - base) else { return }
            edit("Remove Zone") { $0.floating.remove(at: i - base) }
        } else if base > 1 {
            edit("Remove Zone") { $0.root.remove(zone: i) }
        } else {
            NSSound.beep()
            return
        }
        selected = nil
        hovered = nil
    }

    /// The zone whose distances the rulers show.
    private var activeZone: Int? {
        if let id = floatDrag?.id, let k = layout.floating.firstIndex(where: { $0.id == id }) { return layout.root.zoneCount + k }
        return hovered ?? selected // the selected zone keeps its rulers while moved with the keyboard
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
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected == i ? Color.white : Color.orange, lineWidth: selected == i ? 3 : (active ? 2.5 : 1.5)))
            .overlay(label(i, r, real: real))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)).padding(4)
            }
            .frame(width: max(r.width, 1), height: max(r.height, 1))
            .onTapGesture { select(i) }
            .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
            .onContinuousHover(coordinateSpace: .named("canvas")) { phase in
                guard floatDrag == nil else { return }
                if case .active(let p) = phase { Self.cursor(for: Self.edges(at: p, of: r)).set() } else { NSCursor.arrow.set() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                .onChanged { v in
                    if floatDrag?.id != f.id {
                        select(i)
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
                    var l = layout
                    l.floating[k].rect = FloatingZone.fraction(of: snapped, in: canvas)
                    commit(l, drag.edges == .all ? "Move Zone" : "Resize Zone", coalesce: dragKey)
                }
                .onEnded { _ in
                    floatDrag = nil
                    dragKey = UUID().uuidString
                })
            .contextMenu {
                Button("Bring to Front") { edit("Bring to Front") { $0.floating.append($0.floating.remove(at: k)) } }
                    .disabled(k == layout.floating.count - 1)
                Button("Bring Forward") { edit("Bring Forward") { $0.floating.swapAt(k, k + 1) } }
                    .disabled(k == layout.floating.count - 1)
                Button("Send Backward") { edit("Send Backward") { $0.floating.swapAt(k, k - 1) } }
                    .disabled(k == 0)
                Button("Send to Back") { edit("Send to Back") { $0.floating.insert($0.floating.remove(at: k), at: 0) } }
                    .disabled(k == 0)
                Divider()
                Button("Remove Zone") { removeZone(i) }
            }
            .position(x: r.midX, y: r.midY) // last: modifiers after .position would cover the whole canvas
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
            .onHover { inside in
                if inside { (d.axis == .columns ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                .onChanged { v in
                    var l = layout
                    l.root.move(d, to: d.axis == .columns ? v.location.x : v.location.y, spacing: spacing)
                    commit(l, "Resize Zones", coalesce: dragKey)
                }
                .onEnded { _ in dragKey = UUID().uuidString })
            .position(x: hit.midX, y: hit.midY) // last: modifiers after .position would cover the whole canvas
    }
}


/// Dimension lines from a zone's edges to the nearest edge in each direction, with the distance
/// in points (like a design tool's measuring guides).
private struct Rulers: View {
    let measures: [ZoneRuler.Measure]
    /// Canvas points per display point.
    let scale: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            let color = Color.yellow
            for m in measures {
                let a = CGPoint(x: m.from.x * scale, y: m.from.y * scale)
                let b = CGPoint(x: m.to.x * scale, y: m.to.y * scale)
                let horizontal = m.side == .left || m.side == .right
                var line = Path()
                line.move(to: a)
                line.addLine(to: b)
                ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                // End ticks.
                var ticks = Path()
                for p in [a, b] {
                    if horizontal {
                        ticks.move(to: CGPoint(x: p.x, y: p.y - 5)); ticks.addLine(to: CGPoint(x: p.x, y: p.y + 5))
                    } else {
                        ticks.move(to: CGPoint(x: p.x - 5, y: p.y)); ticks.addLine(to: CGPoint(x: p.x + 5, y: p.y))
                    }
                }
                ctx.stroke(ticks, with: .color(color), lineWidth: 1.5)
                // The distance, on a dark pill in the middle of the line.
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let text = ctx.resolve(Text(verbatim: "\(Int(m.distance.rounded()))").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundColor(.black))
                let ts = text.measure(in: CGSize(width: 200, height: 40))
                let pill = CGRect(x: mid.x - ts.width / 2 - 5, y: mid.y - ts.height / 2 - 2, width: ts.width + 10, height: ts.height + 4)
                ctx.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(color))
                ctx.draw(text, at: mid)
            }
        }
    }
}
