# Changelog

## 1.0.1 — 2026-10-04

- Reduce memory use by caching card-sized previews on disk and keeping only visible previews in memory.
- Release previews, full-size images, and window drawing buffers when the selector closes.
- Reuse the selector window and release the Settings window on close to prevent memory growth across repeated opens.
- Limit concurrent image decoding and return freed memory to the system after building the preview cache.
- Wait briefly for previews before animating cards into view.

## 1.0.0 — 2026-10-02

First release.

- Animated slanted-card selector, opened with a global hotkey (⇧⌘W by default)
- Fullscreen morph transition when applying a wallpaper
- Live (video) wallpapers from MP4/MOV files, with an in-card preview
- Options menu (↓): apply to all desktops, this display only, show in Finder, move to Trash
- Type to search, shuffle spin (space), loop-around browsing
- Auto Shuffle on a timer with a slow desktop crossfade
- Settings window: custom hotkey, wallpapers folder, animation speed, looping, Reduce Motion, launch at login
- Lazy, bounded thumbnail loading for large folders
- Respects the macOS Reduce Motion setting
- Universal app (Apple silicon + Intel), macOS 14+
