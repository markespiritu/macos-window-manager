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

### Default shortcuts

| Action | Shortcut |
|---|---|
| Left / Right half | ⌃⌥← / ⌃⌥→ |
| Top / Bottom half | ⌃⌥↑ / ⌃⌥↓ |
| Maximize | ⌃⌥↩ |
| Center | ⌃⌥C |
| Restore (undo) | ⌃⌥⌫ |

All can be changed in Settings › Shortcuts.

### Debug commands

The executable doubles as a CLI that uses the calling terminal's Accessibility grant:

```bash
B="build/Window Manager.app/Contents/MacOS/WindowManagerApp"
"$B" --status                         # permission and private API availability
"$B" --list-windows [--all]           # windows on the current Space
"$B" --list-displays                  # displays, visible frames in AX coordinates
"$B" --list-spaces                    # Spaces per display (SkyLight)
"$B" --action leftHalf --window 1234  # run an action on a window by number
```

## Layout

```
Sources/WindowManagerCore/      no UI; everything testable and reused by later phases
  Geometry/   ScreenCoordinates (AppKit <-> AX flip), LayoutMath (pure frame math)
  Windows/    Window handle, AX helpers, WindowControlling protocol + WindowService
  Displays/   Display (frames already in AX space), DisplayService
  Private/    SkyLight via dlsym (focus, Spaces) and _AXUIElementGetWindow
  Hotkeys/    KeyCombo, HotkeyCenter (Carbon RegisterEventHotKey, id-keyed bindings)
  Actions/    WindowAction (enum of commands), ActionRunner
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
| 1. Foundation (this) | menu bar app, onboarding, window control, hotkeys, settings shell |
| 2. Snapping | `WindowService` + an AXObserver/event-tap drag monitor; `LayoutMath` for zones; a Snapping settings tab |
| 3. Predefined layouts + editor | new `WindowAction` cases / `HotkeyCenter` ids per layout; a Layouts tab |
| 4. Multiple displays and Spaces | `DisplayService`, `SkyLight.managedDisplaySpaces` / `spaces(for:)` |
| 5. Save and restore | `Window.windowID` + app bundle id as keys; persisted beside `SettingsStore` |
| 6. Auto-tiling | `WindowControlling` + `LayoutMath` gaps; window created/destroyed observers |

## Licensing

No GPL code or dependencies, to keep a commercial release possible. No license file yet.
