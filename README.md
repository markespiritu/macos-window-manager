# macOS Window Manager

A menu bar window manager for macOS 14+, written in Swift (SwiftUI + AppKit). No third-party
dependencies.

## Build and run

```bash
scripts/build-app.sh --test      # unit tests (xcodebuild test)
scripts/build-app.sh --run       # build "build/Window Manager.app" and launch it
scripts/build-app.sh --install   # build, copy to /Applications, launch
```

The app is signed with a stable local identity when one is in the keychain ("Automator Local
Signing", then "Apple Development"), so the Accessibility grant survives rebuilds. Set
`SIGN_IDENTITY` to override. On first launch it asks for Accessibility access and closes the
prompt by itself once granted. Opening the app again while it runs shows Settings, which helps
when the menu bar icon is hidden behind the notch.

The executable is `WindowManagerApp`, not `WindowManager`: macOS already runs a system process
called `WindowManager` (Stage Manager), so never `pkill -x WindowManager`.

### Snapping

While you move or resize a window, its edges snap to targets within the snap distance (15 pt by
default, Settings › Snapping):

- the edges of the screen's usable area;
- the facing edge of a neighbouring window, so windows sit flush side by side or stacked;
- the same edge of a window it sits next to, so the tops and bottoms of side-by-side windows (and
  the sides of stacked windows) line up and corners meet.

When resizing, only the edge you drag snaps, so dragging the bottom of the shorter of two
side-by-side windows close to the other's bottom gives them the same height. Snapping can be
turned off from the menu bar.

### Zones (FancyZones-style layouts)

Each display has a zone layout. Hold Option (configurable: Shift, Command or Control) while moving a window to show its zones, and release
over one to drop the window into it (Settings › Zones can show them on every drag instead). Hover
the border between zones to span both; hold Control as well (Shift when Control is the zone key) to span every zone between where
Control went down and the cursor. A window dragged out of a zone gets its previous size back.

- ⌃⌥⌘1–9 picks layout 1–9 for the display of the focused window.
- ⌃⌥⌘← / → moves the focused window to the previous / next zone (on to the next display).

Layouts are trees of splits (`ZoneNode`), so templates (Columns, Rows, Grid, Priority Grid) and
custom layouts edit the same way in Settings › Zones: click a zone to split it, ⇧-click to split
it the other way, drag the lines between zones, right-click to remove one. Layouts are assigned
per display UUID in `ZoneStore`.

### Debug commands

The executable doubles as a CLI that uses the calling terminal's Accessibility grant:

```bash
B="build/Window Manager.app/Contents/MacOS/WindowManagerApp"
"$B" --status                         # permission and private API availability
"$B" --list-windows [--all]           # windows on the current Space
"$B" --list-displays                  # displays, visible frames in AX coordinates
"$B" --list-spaces                    # Spaces per display (SkyLight)
"$B" --snap 1234 [distance]            # snap a window by number as if it had just been moved
```

## Layout

```
Sources/WindowManagerCore/      no UI; everything testable and reused by later phases
  Geometry/   ScreenCoordinates (AppKit <-> AX flip)
  Windows/    Window handle, AX helpers, WindowControlling + WindowService, WindowList (CGWindowList)
  Snapping/   SnapEngine (pure snap math), SnapController (mouse drag monitor that applies it)
  Zones/      ZoneLayout (split tree + templates), ZonePicker, ZoneStore, ZoneOverlay, ZoneController
  Displays/   Display (frames already in AX space), DisplayService
  Private/    SkyLight via dlsym (focus, Spaces) and _AXUIElementGetWindow
  Hotkeys/    KeyCombo, HotkeyCenter (Carbon RegisterEventHotKey; unused until layouts get shortcuts)
  Settings/   SettingsStore (UserDefaults, observable)
  Permissions/AccessibilityPermission (polls until granted)
Sources/WindowManagerApp/       menu bar app: status item, onboarding, settings, debug CLI
Tests/WindowManagerCoreTests/
```

Conventions:

- **One coordinate space.** Everything is in AX space (top-left of the primary display, y down).
  AppKit frames are converted once, in `DisplayService`.
- **Window identity is the CG window number** (`Window.windowID`), which is stable across Spaces.
- **Private APIs are optional.** SkyLight symbols are resolved at runtime; if one disappears the
  code falls back to public API rather than crashing.

## Roadmap

| Phase | Builds on |
|---|---|
| 1. Foundation | menu bar app, onboarding, window control, hotkey plumbing, settings shell |
| 2. Snapping | `SnapEngine` + `SnapController`; Snapping settings tab |
| 3. Zones: predefined layouts + editor (this) | `ZoneLayout`, `ZoneController` (driven by `SnapController`'s drag), Zones tab |
| 4. Multiple displays and Spaces | `DisplayService`, `SkyLight.managedDisplaySpaces` / `spaces(for:)` |
| 5. Save and restore | `Window.windowID` + app bundle id as keys; persisted beside `SettingsStore` |
| 6. Auto-tiling | `WindowControlling`; window created/destroyed observers |

## Licensing

No GPL code or dependencies, to keep a commercial release possible. No license file yet.
