import AppKit
import AVFoundation

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var pixelSize: CGSize {
        CGSize(width: frame.width * backingScaleFactor, height: frame.height * backingScaleFactor)
    }

    static var withMouse: NSScreen {
        screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? main ?? screens[0]
    }
}

private let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))

/// A borderless window that sits on the desktop layer: above the system wallpaper, below icons.
class DesktopWindow: NSWindow {
    init(screen: NSScreen, levelOffset: Int = 0) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: desktopLevel.rawValue + levelOffset)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)
    }
}

enum WallpaperSetter {
    /// Sets a still image on the given screens (current Space), using "Fill Screen".
    static func set(_ url: URL, on screens: [NSScreen]) {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        for screen in screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            } catch {
                NSLog("SlickWallpapers: failed to set wallpaper: \(error)")
            }
        }
    }
}

/// Smooth wallpaper changes without the selector UI (used by auto-shuffle):
/// freezes the current desktop in a window, lets the change happen beneath it, then dissolves.
enum DesktopCrossfade {
    static func perform(on screens: [NSScreen], change: @escaping (_ done: @escaping () -> Void) -> Void) {
        var windows: [NSWindow] = []
        for screen in screens where LiveWallpaper.shared.video(on: screen) == nil {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  let image = Media.full(url, kind: .image, covering: screen.pixelSize) else { continue }
            let window = DesktopWindow(screen: screen, levelOffset: 1)
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.contentsGravity = .resizeAspectFill
            view.layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            window.contentView = view
            window.orderFront(nil)
            windows.append(window)
        }
        change {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = Motion.reduced ? 0.4 : 1.4
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    windows.forEach { $0.animator().alphaValue = 0 }
                }, completionHandler: {
                    windows.forEach { $0.orderOut(nil) }
                })
            }
        }
    }
}

/// Looping, muted video view that fades itself in once the first frame is ready.
/// Optionally masked to the selector's slanted card shape.
final class PlayerView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()
    private let maskLayer = CAShapeLayer()
    private var readyObservation: NSKeyValueObservation?
    var skew: CGFloat? { didSet { needsLayout = true } }

    init(url: URL, fadeDuration: Double) {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.opacity = 0
        layer?.addSublayer(playerLayer)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(fadeDuration)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                self.playerLayer.opacity = 1
                CATransaction.commit()
            }
        }
        player.play()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        if let skew {
            // Layer space is y-up: top edge is at maxY.
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: bounds.maxY))
            p.addLine(to: CGPoint(x: bounds.maxX - skew, y: bounds.maxY))
            p.addLine(to: CGPoint(x: bounds.maxX, y: 0))
            p.addLine(to: CGPoint(x: skew, y: 0))
            p.closeSubpath()
            maskLayer.path = p
            maskLayer.frame = bounds
            playerLayer.mask = maskLayer
        } else {
            playerLayer.mask = nil
        }
        CATransaction.commit()
    }

    func pause() { player.pause() }
    func resume() { player.play() }

    func stop() {
        player.pause()
        looper?.disableLooping()
        player.removeAllItems()
    }
}

/// Video wallpapers: a looping player window per display on the desktop layer.
/// The video's first frame is also set as the still wallpaper, so nothing jumps
/// when the app quits or the display sleeps.
final class LiveWallpaper {
    static let shared = LiveWallpaper()

    private var windows: [CGDirectDisplayID: (url: URL, window: DesktopWindow, player: PlayerView)] = [:]
    private let posterFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SlickWallpapers/Posters", isDirectory: true)

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.windows.values.forEach { $0.player.pause() }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.windows.values.forEach { $0.player.resume() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restore()
        }
    }

    func video(on screen: NSScreen) -> URL? {
        windows[screen.displayID]?.url
    }

    /// Re-creates live wallpapers saved from a previous session.
    func restore() {
        let saved = Settings.shared.liveAssignments
        for screen in NSScreen.screens {
            guard let path = saved[String(screen.displayID)], FileManager.default.fileExists(atPath: path) else { continue }
            if let existing = windows[screen.displayID], existing.url.path == path {
                existing.window.setFrame(screen.frame, display: true)
                continue
            }
            start(URL(fileURLWithPath: path), on: screen, fade: 0.8)
        }
    }

    func play(_ url: URL, on screens: [NSScreen], allDesktops: Bool, completion: @escaping () -> Void) {
        let folder = posterFolder
        DispatchQueue.global(qos: .userInitiated).async {
            var poster: URL?
            if let frame = Media.videoFrame(url, maxSize: nil), let data = Media.pngData(frame) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
                if (try? data.write(to: file, options: .atomic)) != nil { poster = file }
            }
            DispatchQueue.main.async {
                if let poster { WallpaperSetter.set(poster, on: screens) }
                var saved = Settings.shared.liveAssignments
                for screen in screens {
                    self.start(url, on: screen, fade: 0.6)
                    saved[String(screen.displayID)] = url.path
                }
                Settings.shared.liveAssignments = saved
                if allDesktops, let poster {
                    AllDesktops.propagate(poster) { _ in completion() }
                } else {
                    completion()
                }
            }
        }
    }

    func stop(on screens: [NSScreen], fade: Double = 0) {
        var saved = Settings.shared.liveAssignments
        for screen in screens {
            saved[String(screen.displayID)] = nil
            guard let entry = windows.removeValue(forKey: screen.displayID) else { continue }
            close(entry.window, entry.player, fade: fade)
        }
        Settings.shared.liveAssignments = saved
    }

    private func start(_ url: URL, on screen: NSScreen, fade: Double) {
        let old = windows[screen.displayID]
        let window = DesktopWindow(screen: screen)
        let player = PlayerView(url: url, fadeDuration: fade)
        window.contentView = player
        window.orderFront(nil)
        windows[screen.displayID] = (url, window, player)
        // Keep the previous video underneath until the new one has faded in.
        if let old { close(old.window, old.player, fade: 0, after: fade + 1.2) }
    }

    private func close(_ window: NSWindow, _ player: PlayerView, fade: Double, after delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = fade
                window.animator().alphaValue = 0
            }, completionHandler: {
                player.stop()
                window.orderOut(nil)
            })
        }
    }
}
