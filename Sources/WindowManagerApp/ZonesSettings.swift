import AppKit
import SwiftUI
import WindowManagerCore

/// Settings › Zones: preferences, the layout each display uses, and an editor for that layout.
struct ZonesSettings: View {
    @ObservedObject var store: ZoneStore
    @State private var displays = DisplayService.displays
    @State private var displayID: CGDirectDisplayID = DisplayService.displays.first?.id ?? 0
    @State private var confirmDelete = false

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
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
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
                let rects = layout.root.zoneRects(in: CGRect(origin: .zero, size: size), spacing: 3)
                for r in rects {
                    ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(.accentColor.opacity(selected ? 0.55 : 0.3)))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $layout.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Spacer()
                Text("Spacing")
                Slider(value: Binding(get: { layout.spacing }, set: { layout.spacing = $0.rounded() }), in: 0...30).frame(width: 120)
                Text("\(Int(layout.spacing)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .disabled(!canDelete)
                    .help("Delete this layout")
            }
            ZoneCanvas(layout: $layout, screen: screen)
            Text("Click a zone to split it side by side, ⇧-click to split it top and bottom. Drag the lines between zones to resize them. Right-click a zone to remove it.")
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
    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / max(screen.width, 1), geo.size.height / max(screen.height, 1))
            let size = CGSize(width: screen.width * scale, height: screen.height * scale)
            let rect = CGRect(origin: .zero, size: size)
            let spacing = CGFloat(layout.spacing) * scale
            let rects = layout.root.zoneRects(in: rect, spacing: spacing)
            let dividers = layout.root.dividers(in: rect, spacing: spacing)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.25))
                    .frame(width: size.width, height: size.height)
                ForEach(rects.indices, id: \.self) { i in
                    zone(i, rects[i])
                }
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

    private func zone(_ i: Int, _ r: CGRect) -> some View {
        let on = hovered == i
        return RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor.opacity(on ? 0.5 : 0.3))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: on ? 2 : 1))
            .overlay(Text("\(i + 1)").font(.system(size: min(max(min(r.width, r.height) / 4, 11), 28), weight: .semibold)).foregroundStyle(.white))
            .frame(width: max(r.width, 1), height: max(r.height, 1))
            .offset(x: r.minX, y: r.minY)
            .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
            .onTapGesture {
                let rows = NSEvent.modifierFlags.contains(.shift)
                layout.root.split(zone: i, along: rows ? .rows : .columns)
            }
            .contextMenu {
                Button("Split Side by Side") { layout.root.split(zone: i, along: .columns) }
                Button("Split Top and Bottom") { layout.root.split(zone: i, along: .rows) }
                Divider()
                Button("Remove Zone") { layout.root.remove(zone: i) }
                    .disabled(layout.root.zoneCount < 2)
            }
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
            .offset(x: hit.minX, y: hit.minY)
            .onHover { inside in
                if inside { (d.axis == .columns ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas")).onChanged { v in
                layout.root.move(d, to: d.axis == .columns ? v.location.x : v.location.y, spacing: spacing)
            })
    }
}
