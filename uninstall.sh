#!/bin/zsh
# Quits SlickWallpapers and removes the app, its login item and its settings.
# Your wallpapers folder is left untouched.
NAME="SlickWallpapers"
BUNDLE_ID="io.github.ohthegreatgitsby.slickwallpapers"

for app in "$HOME/Applications/$NAME.app" "/Applications/$NAME.app"; do
  [[ -x "$app/Contents/MacOS/$NAME" ]] && "$app/Contents/MacOS/$NAME" --unregister-login 2>/dev/null || true
done
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || pkill -x "$NAME" 2>/dev/null || true
rm -rf "$HOME/Applications/$NAME.app" "/Applications/$NAME.app" 2>/dev/null
defaults delete "$BUNDLE_ID" 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/$NAME"

# Pre-1.0 builds were called "Wallpaper Selector"
launchctl bootout "gui/$(id -u)/com.local.wallpaperselector" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.local.wallpaperselector.plist"
rm -rf "$HOME/Applications/Wallpaper Selector.app"

echo "Uninstalled $NAME."
