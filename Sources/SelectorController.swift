import AppKit
import Combine
import SwiftUI

final class SelectorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectorController {
    let store: WallpaperStore
    let model = SelectorModel()
    var openSettings: (() -> Void)?

    private let settings = Settings.shared
    private let thumbs = ThumbnailCache.shared
    private var panel: SelectorPanel?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var scrollAccum: CGFloat = 0
    private var lastScrollStep = Date.distantPast
    private var busy = false
    private var lastSelected: URL?
    private var subs = Set<AnyCancellable>()

    var isVisible: Bool { panel?.isVisible ?? false }

    init(store: WallpaperStore) {
        self.store = store
        store.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                self.rebuild(animated: self.isVisible)
                if let screen = NSScreen.main, !self.isVisible { self.thumbs.configure(for: screen) }
                self.thumbs.warmDisk(items)
            }
            .store(in: &subs)
        model.$position
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.prefetch() }
            .store(in: &subs)
        // Once the row comes to rest: load the full-res frame and start any video preview.
        model.$position
            .debounce(for: .milliseconds(320), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.model.spinning else { return }
                self.model.settled = true
                self.preloadFull(then: nil)
            }
            .store(in: &subs)
    }

    func toggle() {
        isVisible ? dismiss() : show()
    }

    // MARK: Show / hide

    func show() {
        guard !busy, !isVisible else { return }
        let screen = NSScreen.withMouse
        let panel = self.panel ?? makePanel()
        panel.setFrame(screen.frame, display: false)
        thumbs.configure(for: screen)

        withoutAnimation {
            model.phase = .browsing
            model.appeared = false
            model.nudge = 0
            model.menuOpen = false
            model.query = ""
            model.trashing = nil
            model.badge = nil
            model.settled = false
            model.spinning = false
            model.reduced = Motion.reduced
            rebuild(animated: false)
            if let i = store.index(ofCurrentWallpaperOn: screen) ?? lastSelected.flatMap({ url in model.items.firstIndex { $0.url == url } }) {
                model.position = i
            }
        }
        store.refresh()

        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        installMonitors()

        // Fly the cards in once their previews are decoded (from the disk cache this takes a few
        // milliseconds), so they never appear blank; give up waiting after a moment either way.
        var started = false
        let start = { [weak self] in
            guard let self, !started, self.isVisible else { return }
            started = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                self.model.appeared = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Motion.t(0.5)) { self.model.settled = true }
            }
        }
        let visible = model.entries.filter { abs($0.rel) <= 4 }.map(\.item)
        thumbs.prefetch(visible, done: start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: start)
    }

    /// Everything the selector holds is released while it's closed: every card and its layers,
    /// the previews, the full-size image and the window's drawing buffer. The (empty) window itself
    /// is reused — rebuilding SwiftUI hosting views each time leaks them inside AppKit.
    private func teardown() {
        guard let panel else { return }
        lastSelected = model.selected?.url
        panel.orderOut(nil)
        // A hidden window still owns a backing buffer the size of the screen; shrink it away.
        panel.setFrame(NSRect(x: 0, y: 0, width: 1, height: 1), display: false)
        withoutAnimation {
            model.phase = .browsing
            model.appeared = false
            model.badge = nil
            model.menuOpen = false
            model.items = []
            model.fullURL = nil
            model.fullImage = nil
        }
        thumbs.purge()
        // Layers and textures are released asynchronously; hand freed memory back once they're gone.
        for delay in [0.5, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if self?.isVisible == false { releaseFreedMemory() }
            }
        }
    }

    func dismiss() {
        guard isVisible, !busy, let panel else { return }
        busy = true
        removeMonitors()
        model.settled = false
        model.appeared = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.t(0.26)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.teardown()
            self?.busy = false
        })
    }

    private func makePanel() -> SelectorPanel {
        let panel = SelectorPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let actions = SelectorActions(
            tap: { [weak self] rel in self?.tap(rel) },
            dismiss: { [weak self] in self?.dismiss() },
            runMenu: { [weak self] i in self?.runMenu(i) },
            hoverMenu: { [weak self] i in self?.focusMenu(i) },
            openFolder: { [weak self] in self?.openFolder() }
        )
        let host = NSHostingView(rootView: SelectorView(model: model, thumbs: thumbs, actions: actions))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    // MARK: Items, search

    /// Re-applies the search filter, keeping the focused wallpaper where possible.
    private func rebuild(animated: Bool) {
        let q = model.query.lowercased()
        let list = q.isEmpty ? store.items : store.items.filter {
            $0.name.lowercased().contains(q) || $0.url.lastPathComponent.lowercased().contains(q)
        }
        let previous = model.selected?.url
        let previousIndex = model.selectedIndex ?? 0
        let update = { [self] in
            let oldPosition = model.position
            model.items = list
            model.libraryEmpty = store.items.isEmpty
            model.wraps = settings.loop && list.count >= 3
            if let previous, let i = list.firstIndex(where: { $0.url == previous }) {
                model.position = position(for: i, near: oldPosition, from: previousIndex)
            } else if !model.wraps {
                model.position = min(max(model.position, 0), max(list.count - 1, 0))
            } else if previous == nil || !q.isEmpty {
                model.position = 0
            }
            model.menu = menuItems()
        }
        if animated { withAnimation(Motion.spring(0.5, 0.86)) { update() } } else { update() }
    }

    /// Position that shows item `i`, taking the shortest way round when looping.
    private func position(for i: Int, near current: Int, from currentIndex: Int) -> Int {
        guard model.wraps else { return i }
        let n = model.items.count
        var delta = ((i - currentIndex) % n + n) % n
        if delta > n / 2 { delta -= n }
        return current + delta
    }

    private func type(_ text: String) {
        closeMenu()
        model.query += text
        model.settled = false
        rebuild(animated: true)
    }

    private func deleteBackward() {
        guard !model.query.isEmpty else { return }
        model.query.removeLast()
        rebuild(animated: true)
    }

    private func clearSearch() {
        model.query = ""
        rebuild(animated: true)
    }

    // MARK: Input

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isVisible else { return e }
            self.handleKey(e)
            return nil
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, self.isVisible else { return e }
            self.handleScroll(e)
            return nil
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        scrollMonitor = nil
    }

    private var canInteract: Bool { !busy && model.phase == .browsing && model.appeared }

    private func handleKey(_ e: NSEvent) {
        guard canInteract else { return }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch e.keyCode {
            case 51: trashSelected()          // ⌘⌫
            case 15: revealSelected()         // ⌘R
            case 31: openFolder()             // ⌘O
            case 43: dismiss(); openSettings?() // ⌘,
            case 9: dismiss()                 // ⌘W
            default: break
            }
            return
        }
        switch e.keyCode {
        case 123: closeMenu(); move(-1, repeating: e.isARepeat)           // ←
        case 124: closeMenu(); move(1, repeating: e.isARepeat)            // →
        case 125: model.menuOpen ? stepMenu(1) : openMenu()               // ↓
        case 126: if model.menuOpen { stepMenu(-1) }                      // ↑
        case 36, 76: model.menuOpen ? runMenu(model.menuIndex) : apply(.standard) // ↩
        case 53: escape()                                                 // esc
        case 51: deleteBackward()                                         // ⌫
        case 48: shuffleSpin()                                            // ⇥
        case 49: model.query.isEmpty ? shuffleSpin() : type(" ")          // space
        case 115: jump(toIndex: 0)                                        // home
        case 119: jump(toIndex: model.items.count - 1)                    // end
        default:
            guard !flags.contains(.control), let c = e.characters?.first,
                  c.isLetter || c.isNumber || "-_.'&".contains(c) else { return }
            type(String(c))
        }
    }

    private func escape() {
        if model.menuOpen { closeMenu() } else if !model.query.isEmpty { clearSearch() } else { dismiss() }
    }

    private func handleScroll(_ e: NSEvent) {
        guard canInteract else { return }
        let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        if !e.hasPreciseScrollingDeltas {
            if d != 0 { closeMenu(); move(d > 0 ? -1 : 1) }
            return
        }
        if e.phase == .began { scrollAccum = 0 }
        scrollAccum += d
        if abs(scrollAccum) > 38, Date().timeIntervalSince(lastScrollStep) > 0.11 {
            closeMenu()
            move(scrollAccum > 0 ? -1 : 1, repeating: Date().timeIntervalSince(lastScrollStep) < 0.3)
            scrollAccum = 0
            lastScrollStep = Date()
        }
    }

    private func move(_ dir: Int, repeating: Bool = false) {
        guard canInteract, !model.items.isEmpty, !model.spinning else { return }
        let target = model.position + dir
        if !model.wraps, !model.items.indices.contains(target) {
            return repeating ? () : bump(dir)
        }
        if model.settled { model.settled = false }
        withAnimation(repeating ? Motion.spring(0.26, 1) : Motion.spring(0.46, 0.86)) { model.position = target }
    }

    private func jump(toIndex i: Int) {
        guard canInteract, model.items.indices.contains(i), let current = model.selectedIndex else { return }
        closeMenu()
        model.settled = false
        withAnimation(Motion.spring(0.6, 0.88)) {
            model.position = position(for: i, near: model.position, from: current)
        }
    }

    /// Rubber-band nudge when trying to scroll past either end.
    private func bump(_ dir: Int) {
        guard !model.reduced else { return }
        withAnimation(.spring(response: 0.16, dampingFraction: 1)) { model.nudge = CGFloat(-dir) * 22 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.55)) { self?.model.nudge = 0 }
        }
    }

    private func tap(_ rel: Int) {
        guard canInteract else { return }
        if rel == 0 {
            model.menuOpen ? closeMenu() : apply(.standard)
        } else {
            closeMenu()
            model.settled = false
            withAnimation(Motion.spring(0.55, 0.88)) { model.position += rel }
        }
    }

    // MARK: Shuffle

    /// Slot-machine spin that decelerates onto a random wallpaper.
    func shuffleSpin() {
        guard canInteract, !model.spinning, model.items.count > 1, let current = model.selectedIndex else { return }
        closeMenu()
        let n = model.items.count
        var target = Int.random(in: 0..<(n - 1))
        if target >= current { target += 1 }

        if model.reduced {
            jump(toIndex: target)
            return
        }

        var steps: Int, dir: Int
        if model.wraps {
            let forward = ((target - current) % n + n) % n
            steps = forward + n * max(1, 10 / n)
            if steps > 18 {
                // Skip the middle laps invisibly, then spin the last stretch.
                let skip = steps - 18
                withoutAnimation { model.position += skip }
                steps = 18
            }
            dir = 1
        } else {
            steps = abs(target - current)
            dir = target > current ? 1 : -1
        }

        model.settled = false
        model.spinning = steps > 3
        var t = 0.0
        for s in 0..<steps {
            let p = steps > 1 ? Double(s) / Double(steps - 1) : 1
            let interval = Motion.t(0.05 + 0.24 * pow(p, 2.4))
            t += interval
            let last = s == steps - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self else { return }
                withAnimation(.spring(response: max(0.16, interval * 2.4), dampingFraction: last ? 0.72 : 1)) {
                    self.model.position += dir
                    if p > 0.6 { self.model.spinning = false }
                }
                if last {
                    self.model.spinning = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.model.settled = true
                        self.preloadFull(then: nil)
                    }
                }
            }
        }
    }

    // MARK: Menu

    private func menuItems() -> [MenuItem] {
        guard let item = model.selected else { return [] }
        var items: [MenuItem] = []
        if item.kind == .video {
            items.append(MenuItem(action: .allDesktops, title: "Live on All Desktops", icon: "play.rectangle.on.rectangle"))
        } else {
            items.append(MenuItem(action: .allDesktops, title: "Apply to All Desktops", icon: "rectangle.on.rectangle"))
        }
        if NSScreen.screens.count > 1 {
            items.append(MenuItem(action: .thisDisplay, title: "This Display Only", icon: "display"))
        }
        items.append(MenuItem(action: .reveal, title: "Show in Finder", icon: "folder"))
        items.append(MenuItem(action: .trash, title: "Move to Trash", icon: "trash", destructive: true))
        return items
    }

    private func openMenu() {
        guard canInteract, model.selected != nil, !model.spinning else { return }
        model.menu = menuItems()
        model.menuIndex = 0
        withAnimation(Motion.spring(0.42, 0.8)) { model.menuOpen = true }
    }

    private func closeMenu() {
        guard model.menuOpen else { return }
        withAnimation(Motion.spring(0.38, 0.9)) { model.menuOpen = false }
    }

    private func stepMenu(_ d: Int) {
        let next = model.menuIndex + d
        if next < 0 { return closeMenu() }
        guard next < model.menu.count else { return }
        focusMenu(next)
    }

    private func focusMenu(_ i: Int) {
        guard model.menuOpen, model.menuIndex != i else { return }
        withAnimation(Motion.spring(0.3, 0.82)) { model.menuIndex = i }
    }

    private func runMenu(_ i: Int) {
        guard canInteract, model.menu.indices.contains(i) else { return }
        switch model.menu[i].action {
        case .allDesktops: apply(.allDesktops)
        case .thisDisplay: apply(.thisDisplay)
        case .reveal: revealSelected()
        case .trash: trashSelected()
        }
    }

    // MARK: File actions

    private func revealSelected() {
        guard let item = model.selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
        dismiss()
    }

    private func trashSelected() {
        guard canInteract, let item = model.selected else { return }
        closeMenu()
        busy = true
        withAnimation(Motion.reduced ? .easeIn(duration: 0.2) : .timingCurve(0.5, 0, 0.75, 0, duration: Motion.t(0.42))) {
            model.trashing = item.url
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.t(0.4)) { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            } catch {
                NSSound.beep()
                withAnimation(Motion.spring(0.5)) { self.model.trashing = nil }
                self.busy = false
                return
            }
            self.store.refresh {
                self.model.trashing = nil
                self.busy = false
                self.model.settled = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.model.settled = true }
            }
        }
    }

    private func openFolder() {
        NSWorkspace.shared.open(store.folder)
        dismiss()
    }

    // MARK: Apply

    enum Target { case standard, allDesktops, thisDisplay }

    private func prefetch() {
        let n = model.items.count
        guard n > 0, let current = model.selectedIndex else { return }
        let range = model.wraps ? Array(-6...6) : Array(max(-current, -6)...min(n - 1 - current, 6))
        thumbs.prefetch(range.map { model.items[((current + $0) % n + n) % n] })
    }

    private func preloadFull(then done: (() -> Void)?) {
        guard let item = model.selected, let panel else { done?(); return }
        if model.fullURL == item.url, model.fullImage != nil { done?(); return }
        let pixels = (panel.screen ?? NSScreen.withMouse).pixelSize
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = autoreleasepool { Media.full(item.url, kind: item.kind, covering: pixels) }
            DispatchQueue.main.async {
                guard let self else { return }
                if let image, self.model.selected?.url == item.url {
                    self.model.fullURL = item.url
                    self.model.fullImage = image
                }
                done?()
            }
        }
    }

    private func apply(_ target: Target) {
        guard canInteract, !model.spinning, let item = model.selected, let panel else { return }
        let screen = panel.screen ?? NSScreen.withMouse
        busy = true
        removeMonitors()
        closeMenu()
        model.settled = false

        switch (target, item.kind) {
        case (.allDesktops, .video): model.badge = "Live on all desktops"
        case (.allDesktops, _): model.badge = "Applied to all desktops"
        case (.thisDisplay, _): model.badge = "Applied to \(screen.localizedName)"
        case (.standard, .video): model.badge = "Live wallpaper on"
        default: model.badge = nil
        }

        preloadFull { [weak self] in
            guard let self else { return }
            let morph = Motion.reduced ? 0.45 : Motion.t(0.9)
            withAnimation(Motion.reduced ? .easeInOut(duration: 0.45) : .timingCurve(0.72, 0, 0.16, 1, duration: morph)) {
                self.model.phase = .applying
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + morph + 0.02) {
                let screens = target == .thisDisplay ? [screen] : NSScreen.screens
                // The fullscreen card still covers everything while the desktop changes underneath.
                switch item.kind {
                case .video:
                    LiveWallpaper.shared.play(item.url, on: screens, allDesktops: target == .allDesktops) {
                        self.reveal(after: 0.6)
                    }
                case .image:
                    LiveWallpaper.shared.stop(on: screens)
                    WallpaperSetter.set(item.url, on: screens)
                    if target == .allDesktops {
                        AllDesktops.propagate(item.url) { ok in
                            if !ok { NSLog("SlickWallpapers: could not propagate wallpaper to all desktops") }
                            self.reveal(after: ok ? 0.75 : 0.1)
                        }
                    } else {
                        self.reveal(after: 0.4)
                    }
                }
            }
        }
    }

    private func reveal(after delay: Double) {
        guard let panel else { return }
        let hold = model.badge != nil ? max(delay, Motion.t(0.9)) : delay
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Motion.t(0.45)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.teardown()
                self?.busy = false
            })
        }
    }
}

func withoutAnimation(_ body: () -> Void) {
    var t = Transaction()
    t.disablesAnimations = true
    withTransaction(t, body)
}
