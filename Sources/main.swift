import AppKit
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private lazy var store = WallpaperStore(folder: settings.folderURL)
    private lazy var selector = SelectorController(store: store)
    private lazy var settingsWindow = SettingsWindowController(store: store) { [weak self] in self?.shuffleInBackground() }
    private var statusItem: NSStatusItem?
    private var openItem: NSMenuItem?
    private var shuffleTimer: Timer?
    private var subs = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.use(folder: settings.folderURL)
        LiveWallpaper.shared.restore()

        HotKeyCenter.shared.action = { [weak self] in self?.selector.toggle() }
        selector.openSettings = { [weak self] in self?.settingsWindow.show() }

        settings.$shortcut
            .sink { [weak self] shortcut in
                guard let self else { return }
                self.settings.hotKeyError = HotKeyCenter.shared.register(shortcut)
                    ? nil : "\(shortcut.display) is already used by another app. Pick a different shortcut."
                self.openItem?.title = "Choose Wallpaper…  \(shortcut.display)"
            }
            .store(in: &subs)
        settings.$folderPath
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self.map { $0.store.use(folder: $0.settings.folderURL) } }
            }
            .store(in: &subs)
        settings.$shuffleMinutes
            .sink { [weak self] minutes in self?.scheduleShuffle(minutes) }
            .store(in: &subs)

        setupStatusItem()

        if !settings.hasLaunchedBefore {
            settings.hasLaunchedBefore = true
            settings.launchAtLogin = true
            settingsWindow.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "SlickWallpapers")
        let menu = NSMenu()
        let open = NSMenuItem(title: "Choose Wallpaper…  \(settings.shortcut.display)", action: #selector(showSelector), keyEquivalent: "")
        openItem = open
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Shuffle Now", action: #selector(shuffleNow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Wallpapers Folder", action: #selector(openFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SlickWallpapers", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.filter { $0.action != #selector(NSApplication.terminate(_:)) }.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showSelector() { selector.show() }
    @objc private func showSettings() { settingsWindow.show() }
    @objc private func openFolder() { NSWorkspace.shared.open(store.folder) }
    @objc private func shuffleNow() { shuffleInBackground() }

    // MARK: Auto shuffle

    private func scheduleShuffle(_ minutes: Int) {
        shuffleTimer?.invalidate()
        shuffleTimer = nil
        guard minutes > 0 else { return }
        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            self?.shuffleInBackground()
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        shuffleTimer = timer
    }

    /// Changes the wallpaper without showing the selector, with a slow desktop crossfade.
    private func shuffleInBackground() {
        guard !selector.isVisible else { return selector.shuffleSpin() }
        let main = NSScreen.main ?? NSScreen.screens[0]
        let current = store.index(ofCurrentWallpaperOn: main)
        let candidates = store.items.indices.filter { $0 != current }
        guard let pick = candidates.randomElement() else { return }
        let item = store.items[pick]
        let screens = NSScreen.screens
        let allDesktops = settings.shuffleAllDesktops

        switch item.kind {
        case .video:
            LiveWallpaper.shared.play(item.url, on: screens, allDesktops: allDesktops) {}
        case .image:
            DesktopCrossfade.perform(on: screens) { done in
                LiveWallpaper.shared.stop(on: screens, fade: Motion.reduced ? 0.4 : 1.4)
                WallpaperSetter.set(item.url, on: screens)
                if allDesktops {
                    AllDesktops.propagate(item.url) { _ in done() }
                } else {
                    done()
                }
            }
        }
    }
}

// Used by uninstall.sh to remove the login item before the app is deleted.
if CommandLine.arguments.contains("--unregister-login") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
