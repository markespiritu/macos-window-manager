#!/usr/bin/env bash
# Builds "Window Manager.app" into ./build with xcodebuild.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --run      build, then (re)launch from ./build
#   scripts/build-app.sh --install  build, copy to /Applications, launch
#   scripts/build-app.sh --test     run the unit tests
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=build/DerivedData
if [[ "${1:-}" == "--test" ]]; then
    exec xcodebuild test -scheme WindowManager-Package -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED" -quiet
fi

xcodebuild build -scheme WindowManagerApp -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" -quiet
BIN="$DERIVED/Build/Products/Release/WindowManagerApp"

APP="build/Window Manager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WindowManagerApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sign with a stable identity when one exists so the Accessibility grant survives rebuilds
# (an ad-hoc signature changes every build, and macOS then treats it as a new app).
IDENTITY="${SIGN_IDENTITY:-}"
for CANDIDATE in "Automator Local Signing" "Apple Development"; do
    if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning | grep -q "\"$CANDIDATE"; then
        IDENTITY=$(security find-identity -p codesigning | grep "\"$CANDIDATE" | head -1 | sed -E 's/.*"(.*)".*/\1/')
    fi
done
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

case "${1:-}" in
    --run)
        pkill -x WindowManagerApp 2>/dev/null || true
        open "$APP" ;;
    --install)
        pkill -x WindowManagerApp 2>/dev/null || true
        rm -rf "/Applications/Window Manager.app"
        cp -R "$APP" /Applications/
        open "/Applications/Window Manager.app"
        echo "Installed /Applications/Window Manager.app" ;;
esac
