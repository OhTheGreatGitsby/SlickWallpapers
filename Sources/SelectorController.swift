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

    private var panel: SelectorPanel?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var scrollAccum: CGFloat = 0
    private var lastScrollStep = Date.distantPast
    private var busy = false
    private var preloadSub: AnyCancellable?

    private var isVisible: Bool { panel?.isVisible ?? false }

    init(store: WallpaperStore) {
        self.store = store
        // Preload the full-resolution image for whatever card the user settles on.
        preloadSub = model.$selected
            .debounce(for: .milliseconds(160), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.preloadFull(then: nil) }
    }

    func toggle() {
        isVisible ? dismiss() : show()
    }

    // MARK: Show / hide

    func show() {
        guard !busy else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let panel = self.panel ?? makePanel()
        panel.setFrame(screen.frame, display: false)

        withoutAnimation {
            model.phase = .browsing
            model.appeared = false
            model.nudge = 0
            model.showOptions = false
            model.allDesktops = false
            model.selected = store.index(ofCurrentWallpaperOn: screen) ?? clamped(model.selected)
        }
        store.refresh { [weak self] in
            guard let self else { return }
            self.model.selected = self.clamped(self.model.selected)
        }

        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        // Give SwiftUI one frame in the "hidden" state, then fly the cards in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.model.appeared = true
        }
    }

    func dismiss() {
        guard isVisible, !busy, let panel else { return }
        busy = true
        removeMonitors()
        model.appeared = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.busy = false
        })
    }

    private func makePanel() -> SelectorPanel {
        let panel = SelectorPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let actions = SelectorActions(
            tap: { [weak self] i in self?.tap(i) },
            dismiss: { [weak self] in self?.dismiss() },
            applyAll: { [weak self] in self?.apply(allDesktops: true) },
            openFolder: { [weak self] in self?.openFolder() }
        )
        let host = NSHostingView(rootView: SelectorView(model: model, store: store, actions: actions))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
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

    private func handleKey(_ e: NSEvent) {
        switch e.keyCode {
        case 123: closeOptions(); move(-1)                 // ←
        case 124: closeOptions(); move(1)                  // →
        case 125: openOptions()                            // ↓
        case 126: closeOptions()                           // ↑
        case 36, 76, 49: apply(allDesktops: model.showOptions) // return, keypad enter, space
        case 53: model.showOptions ? closeOptions() : dismiss() // esc
        case 31: openFolder()            // O
        case 115: jump(to: 0)            // home
        case 119: jump(to: store.items.count - 1) // end
        default: break
        }
    }

    private func handleScroll(_ e: NSEvent) {
        let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        if !e.hasPreciseScrollingDeltas {
            if d != 0 { move(d > 0 ? -1 : 1) }
            return
        }
        if e.phase == .began { scrollAccum = 0 }
        scrollAccum += d
        if abs(scrollAccum) > 38, Date().timeIntervalSince(lastScrollStep) > 0.11 {
            move(scrollAccum > 0 ? -1 : 1)
            scrollAccum = 0
            lastScrollStep = Date()
        }
    }

    private func move(_ dir: Int) {
        guard !busy, model.phase == .browsing, !store.items.isEmpty else { return }
        closeOptions()
        let target = model.selected + dir
        guard store.items.indices.contains(target) else { return bump(dir) }
        withAnimation(.spring(response: 0.46, dampingFraction: 0.86)) {
            model.selected = target
        }
    }

    private func openOptions() {
        guard !busy, model.phase == .browsing, !store.items.isEmpty, !model.showOptions else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { model.showOptions = true }
    }

    private func closeOptions() {
        guard model.showOptions else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { model.showOptions = false }
    }

    private func jump(to index: Int) {
        guard !busy, store.items.indices.contains(index) else { return }
        closeOptions()
        withAnimation(.spring(response: 0.6, dampingFraction: 0.88)) { model.selected = index }
    }

    /// Rubber-band nudge when trying to scroll past either end.
    private func bump(_ dir: Int) {
        withAnimation(.spring(response: 0.16, dampingFraction: 1)) { model.nudge = CGFloat(-dir) * 22 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.55)) { self?.model.nudge = 0 }
        }
    }

    private func tap(_ i: Int) {
        guard !busy else { return }
        if i == model.selected { apply() } else { jump(to: i) }
    }

    private func openFolder() {
        NSWorkspace.shared.open(WallpaperStore.folder)
        dismiss()
    }

    // MARK: Apply

    private func preloadFull(then done: (() -> Void)?) {
        guard store.items.indices.contains(model.selected), let panel else { done?(); return }
        let url = store.items[model.selected].url
        if model.fullURL == url, model.fullImage != nil { done?(); return }
        let scale = panel.screen?.backingScaleFactor ?? 2
        let pixels = CGSize(width: panel.frame.width * scale, height: panel.frame.height * scale)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = ImageLoader.full(url, covering: pixels)
            DispatchQueue.main.async {
                guard let self else { return }
                if let image, self.store.items.indices.contains(self.model.selected),
                   self.store.items[self.model.selected].url == url {
                    self.model.fullURL = url
                    self.model.fullImage = image
                }
                done?()
            }
        }
    }

    private func apply(allDesktops: Bool = false) {
        guard !busy, model.phase == .browsing, model.appeared,
              store.items.indices.contains(model.selected), let panel else { return }
        busy = true
        let url = store.items[model.selected].url
        model.allDesktops = allDesktops

        preloadFull { [weak self] in
            guard let self else { return }
            let morph = 0.9
            withAnimation(.timingCurve(0.72, 0, 0.16, 1, duration: morph)) {
                self.model.phase = .applying
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + morph + 0.02) {
                self.setWallpaper(url)
                // Let the system repaint the desktop underneath (and, for all desktops, let the
                // restarted agent come back) while the fullscreen card still covers everything.
                let reveal = { (delay: Double) in DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.removeMonitors()
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.45
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        panel.animator().alphaValue = 0
                    }, completionHandler: {
                        panel.orderOut(nil)
                        withoutAnimation {
                            self.model.phase = .browsing
                            self.model.appeared = false
                        }
                        self.busy = false
                    })
                } }
                if allDesktops {
                    AllDesktops.propagate(url) { ok in
                        if !ok { NSLog("WallpaperSelector: could not propagate wallpaper to all desktops") }
                        reveal(ok ? 0.75 : 0.1)
                    }
                } else {
                    reveal(0.4)
                }
            }
        }
    }

    private func setWallpaper(_ url: URL) {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            } catch {
                NSLog("WallpaperSelector: failed to set wallpaper: \(error)")
            }
        }
    }

    private func clamped(_ i: Int) -> Int {
        min(max(i, 0), max(store.items.count - 1, 0))
    }
}

private func withoutAnimation(_ body: () -> Void) {
    var t = Transaction()
    t.disablesAnimations = true
    withTransaction(t, body)
}
