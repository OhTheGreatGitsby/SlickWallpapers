#!/bin/zsh
# Builds SlickWallpapers.app.
#
#   ./build.sh            build for this Mac, install to ~/Applications and launch
#   ./build.sh --release  build a universal (Apple silicon + Intel) app and zip it into dist/
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
NAME="SlickWallpapers"
BUNDLE_ID="io.github.ohthegreatgitsby.slickwallpapers"
MIN_MACOS="14.0"
MODE="${1:-install}"

APP="build/$NAME.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Use the default SDK; if this compiler can't read it (Command Line Tools sometimes ship an SDK newer
# than their Swift compiler), fall back to the other installed SDKs, newest first.
compile() { # $1 = arch, $2 = output
  local sdks=("$(xcrun --show-sdk-path)")
  sdks+=(${(On)$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null)})
  for sdk in $sdks; do
    if swiftc -O -swift-version 5 -sdk "$sdk" -target "$1-apple-macos$MIN_MACOS" \
         Sources/*.swift -o "$2" 2>build/compile.log; then
      return 0
    fi
    grep -q "this SDK is not supported by the compiler" build/compile.log || break
  done
  cat build/compile.log >&2
  return 1
}

if [[ "$MODE" == "--release" ]]; then
  compile arm64 build/arm64
  compile x86_64 build/x86_64
  lipo -create build/arm64 build/x86_64 -output "$APP/Contents/MacOS/$NAME"
else
  compile "$(uname -m)" "$APP/Contents/MacOS/$NAME"
fi

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"

if [[ "$MODE" == "--release" ]]; then
  mkdir -p dist && rm -f "dist/$NAME.zip"
  ditto -c -k --keepParent "$APP" "dist/$NAME.zip"
  echo "Built dist/$NAME.zip ($(lipo -archs "$APP/Contents/MacOS/$NAME"))"
  exit 0
fi

# Install: stop any running copy (including the pre-1.0 "Wallpaper Selector"), then launch.
OLD_AGENT="$HOME/Library/LaunchAgents/com.local.wallpaperselector.plist"
launchctl bootout "gui/$(id -u)/com.local.wallpaperselector" 2>/dev/null || true
rm -f "$OLD_AGENT"
rm -rf "$HOME/Applications/Wallpaper Selector.app"
pkill -x WallpaperSelector 2>/dev/null || true
pkill -x "$NAME" 2>/dev/null || true

DEST="$HOME/Applications/$NAME.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST" && cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed → $DEST"
