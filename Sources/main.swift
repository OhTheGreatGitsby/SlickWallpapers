import AppKit
import Carbon.HIToolbox

/// System-wide hotkey via Carbon — needs no Accessibility permission.
final class HotKey {
    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x5750_534C), id: 1) // "WPSL"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = WallpaperStore()
    lazy var controller = SelectorController(store: store)
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.ensureFolder()
        store.startWatching()
        store.refresh()

        hotKey = HotKey(keyCode: kVK_ANSI_W, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.controller.toggle()
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "Wallpaper Selector")
        let menu = NSMenu()
        let show = NSMenuItem(title: "Choose Wallpaper…", action: #selector(showSelector), keyEquivalent: "w")
        show.keyEquivalentModifierMask = [.command, .shift]
        show.target = self
        menu.addItem(show)
        let folder = NSMenuItem(title: "Open Wallpapers Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Wallpaper Selector", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func showSelector() { controller.show() }
    @objc private func openFolder() { NSWorkspace.shared.open(WallpaperStore.folder) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
