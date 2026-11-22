#!/bin/zsh
# Builds a release "Mouse Studio.app" into ./build. Needs only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | grep -E "error|Compiling|Build" | tail -3

APP="build/Mouse Studio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MouseStudio "$APP/Contents/MacOS/MouseStudio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Translations (one folder per language, e.g. vi.lproj/Localizable.strings).
for lproj in Resources/*.lproj; do [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"; done

# Sign with a fixed identifier requirement so macOS keeps the Accessibility permission across rebuilds.
codesign --force --sign - --identifier com.mousestudio.app \
    --requirements '=designated => identifier "com.mousestudio.app"' "$APP"
echo "Built: $APP"
