#!/bin/zsh
# Builds Wallpaper Selector.app, installs it to ~/Applications and registers it to start at login.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Wallpaper Selector.app"
DEST="$HOME/Applications/Wallpaper Selector.app"
LABEL="com.local.wallpaperselector"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

rm -rf build && mkdir -p "$APP/Contents/MacOS"
SDK="$(xcrun --show-sdk-path)"; [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]] && SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
swiftc -O -swift-version 5 -sdk "$SDK" -target arm64-apple-macos14 \
  Sources/*.swift -o "$APP/Contents/MacOS/WallpaperSelector"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Wallpaper Selector</string>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleExecutable</key><string>WallpaperSelector</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"

# Install (stop any running copy first)
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x WallpaperSelector 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST" && cp -R "$APP" "$DEST"

cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/WallpaperSelector</string></array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Installed → $DEST (running, starts at login). Press ⇧⌘W."
