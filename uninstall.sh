#!/bin/zsh
# Stops SlickWallpapers, removes the login item and the installed app. Your ~/Wallpapers folder is left untouched.
LABEL="com.local.wallpaperselector"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x WallpaperSelector 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Wallpaper Selector.app"
echo "Uninstalled."
