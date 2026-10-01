# SlickWallpapers

SlickWallpapers is an open-source macOS tool that gives you a clean, smooth wallpaper switcher, similar to the Quickshell wallpaper pickers on Linux.

Press **⇧⌘W** anywhere. Your wallpapers fly in as a row of slanted cards. Browse them with the arrow keys and press **Enter**. The card you picked straightens out and grows to fill the screen, then becomes your wallpaper.

## Features

- **Animated card selector:** slanted cards with a parallax effect, spring-based motion, and cards that fly in one after another.
- **Smooth switch:** the selected card expands to fill the screen at full resolution. The real wallpaper is then set underneath it, and the overlay fades away.
- **Apply to all desktops:** press **↓** on a wallpaper, then **Enter**, to set it on every Space and every display.
- **Drop-in folder:** put images in `~/Wallpapers` and they show up the next time you open the selector, with no restart needed (PNG, JPG, HEIC, WebP, TIFF, GIF, BMP).
- **Native and lightweight:** Swift + SwiftUI with no dependencies. It runs as a menu bar app with no Dock icon.
- **No permissions needed:** the global hotkey doesn't require Accessibility access.

## Controls

| Key | Action |
| --- | --- |
| **⇧⌘W** | Open or close the selector |
| **← →** | Browse wallpapers (trackpad swipe, scroll wheel and clicking also work) |
| **↩** | Apply to the current desktop |
| **↓** then **↩** | Apply to **all** desktops |
| **↑** | Back out of the options |
| **O** | Open the `~/Wallpapers` folder |
| **esc** | Close |

## Install

Requirements: macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/OhTheGreatGitsby/SlickWallpapers.git
cd SlickWallpapers
./build.sh
```

`build.sh` does the following:
1. Compiles the app.
2. Installs it to `~/Applications/Wallpaper Selector.app`.
3. Registers it to start at login.
4. Launches it.

After that, put some images into `~/Wallpapers` and press **⇧⌘W**.

To remove the app, run `./uninstall.sh`. Your `~/Wallpapers` folder is left untouched.

## Notes

- **Hotkey conflict:** ⇧⌘W is "Close Window" in many apps. The global hotkey takes priority over it. To change the shortcut, edit `HotKey(keyCode:modifiers:)` in `Sources/main.swift`.
- **How "All Desktops" works:** macOS only offers a public API to change the wallpaper of the *current* Space. To cover every Space, SlickWallpapers sets the wallpaper on the current Space first. It then copies that entry to every Space in `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` and restarts `WallpaperAgent` so the change takes effect. This relies on how macOS stores wallpapers internally, which isn't an official interface, so a future macOS release may change it.
- **Build error about the SDK not being supported by the compiler:** your Command Line Tools ship an SDK newer than the Swift compiler. `build.sh` automatically uses the macOS 26 SDK if it's installed.

## Project layout

```
Sources/
  main.swift                 App entry, global hotkey, menu bar item
  SelectorController.swift   Panel window, input handling, apply flow
  SelectorView.swift         SwiftUI selector UI and animations
  WallpaperStore.swift       ~/Wallpapers scanning, watching, thumbnails
  AllDesktops.swift          "Apply to all desktops" support
build.sh                     Build + install + launch at login
uninstall.sh                 Remove everything
```

## License

[MIT](LICENSE)
