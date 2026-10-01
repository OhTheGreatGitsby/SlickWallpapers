import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?
    private let store: WallpaperStore
    private let shuffleNow: () -> Void

    init(store: WallpaperStore, shuffleNow: @escaping () -> Void) {
        self.store = store
        self.shuffleNow = shuffleNow
    }

    func show() {
        let window = self.window ?? make()
        if !window.isVisible {
            window.center()
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                window.animator().alphaValue = 1
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.title = "SlickWallpapers Settings"

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        let host = NSHostingView(rootView: SettingsView(settings: .shared, store: store, thumbs: .shared, shuffleNow: shuffleNow))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        window.contentView = effect
        self.window = window
        return window
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var store: WallpaperStore
    @ObservedObject var thumbs: ThumbnailCache
    let shuffleNow: () -> Void
    @State private var appeared: Bool

    init(settings: Settings, store: WallpaperStore, thumbs: ThumbnailCache, shuffleNow: @escaping () -> Void, animateIn: Bool = true) {
        self.settings = settings
        self.store = store
        self.thumbs = thumbs
        self.shuffleNow = shuffleNow
        _appeared = State(initialValue: !animateIn)
    }

    var body: some View {
        ScrollView {
            content
        }
        .scrollIndicators(.never)
        .frame(width: 560, height: 720)
        .background(
            LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.12).opacity(0.55), Color(red: 0.10, green: 0.05, blue: 0.14).opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
        )
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { appeared = true }
        }
    }

    var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                header
                    .padding(.bottom, 4)

                section("Shortcut", 0) {
                    row("Open selector") {
                        ShortcutRecorder(settings: settings)
                    }
                    if let error = settings.hotKeyError {
                        note(error, warning: true)
                    }
                }

                section("Library", 1) {
                    row("Wallpapers folder") {
                        HStack(spacing: 8) {
                            Text(settings.folderPath)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 170, alignment: .trailing)
                                .opacity(0.75)
                            Button("Change…", action: chooseFolder)
                            Button { NSWorkspace.shared.open(settings.folderURL) } label: { Image(systemName: "arrow.up.forward.app") }
                                .help("Open in Finder")
                        }
                    }
                    note("\(store.items.count) wallpaper\(store.items.count == 1 ? "" : "s"). Images (PNG, JPG, HEIC, WebP…) and videos (MP4, MOV); videos become live wallpapers.")
                }

                section("Motion", 2) {
                    row("Animation speed") {
                        Picker("", selection: $settings.motion) {
                            ForEach(MotionSpeed.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 230)
                    }
                    divider
                    toggle("Loop around", "After the last wallpaper, continue with the first.", $settings.loop)
                    divider
                    toggle("Reduce motion", "Use simple fades instead of movement. Always on when Reduce Motion is enabled in System Settings › Accessibility.", $settings.reduceMotion)
                }

                section("Auto Shuffle", 3) {
                    row("Change wallpaper") {
                        Picker("", selection: $settings.shuffleMinutes) {
                            ForEach(Settings.shuffleChoices, id: \.minutes) { Text($0.title).tag($0.minutes) }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    divider
                    toggle("Apply to all desktops", "Shuffled wallpapers cover every Space, not just the current one.", $settings.shuffleAllDesktops)
                    divider
                    row("Pick one at random now") {
                        Button {
                            shuffleNow()
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .disabled(store.items.count < 2)
                    }
                }

                section("General", 4) {
                    toggle("Launch at login", nil, $settings.launchAtLogin)
                    if let error = settings.loginItemError {
                        note(error, warning: true)
                    }
                }

                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 24)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 18) {
            MiniCarousel(items: Array(store.items.prefix(7)), thumbs: thumbs)
                .frame(width: 210, height: 112)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                             .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
            VStack(alignment: .leading, spacing: 6) {
                Text("SlickWallpapers")
                    .font(.system(size: 24, weight: .bold))
                Text("Version \(settings.version)")
                    .font(.system(size: 12, weight: .medium))
                    .opacity(0.5)
                HStack(spacing: 6) {
                    Text("Press")
                    Text(settings.shortcut.display)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.14)))
                    Text("anywhere")
                }
                .font(.system(size: 12.5))
                .opacity(0.8)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
    }

    private var footer: some View {
        HStack {
            Link(destination: URL(string: "https://github.com/OhTheGreatGitsby/SlickWallpapers")!) {
                Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Spacer()
            Button("Quit SlickWallpapers") { NSApp.terminate(nil) }
        }
        .font(.system(size: 12))
        .padding(.top, 4)
        .opacity(appeared ? 0.8 : 0)
        .animation(.easeOut(duration: 0.4).delay(0.3), value: appeared)
    }

    private func section<Content: View>(_ title: String, _ order: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(1.3)
                .opacity(0.45)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        }
        .foregroundStyle(.white)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .animation(.spring(response: 0.6, dampingFraction: 0.86).delay(0.05 + 0.05 * Double(order)), value: appeared)
    }

    private func row<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            trailing()
        }
    }

    private func toggle(_ title: String, _ detail: String?, _ value: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 11.5)).opacity(0.5).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            Toggle("", isOn: value).toggleStyle(.switch).labelsHidden()
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if warning { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
        .opacity(warning ? 0.9 : 0.5)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = settings.folderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        settings.folderPath = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

/// Click, then press the new key combination. Esc cancels.
struct ShortcutRecorder: View {
    @ObservedObject var settings: Settings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: { recording ? stop() : start() }) {
            HStack(spacing: 6) {
                if recording {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                }
                Text(recording ? "Type shortcut…" : settings.shortcut.display)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .frame(minWidth: 130, minHeight: 28)
            .background(Capsule().fill(recording ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.1)))
            .overlay(Capsule().strokeBorder(.white.opacity(recording ? 0.5 : 0.15), lineWidth: 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: recording)
        }
        .buttonStyle(.plain)
        .help("Click, then press a key combination with ⌘, ⌥ or ⌃")
        .onDisappear(perform: stop)
    }

    private func start() {
        HotKeyCenter.shared.unregister()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 {
                stop()
            } else if let shortcut = Shortcut.from(e) {
                settings.shortcut = shortcut
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        settings.hotKeyError = HotKeyCenter.shared.register(settings.shortcut)
            ? nil : "\(settings.shortcut.display) is already used by another app. Pick a different shortcut."
    }
}

/// The selector in miniature: slanted cards that drift along by themselves.
private struct MiniCarousel: View {
    let items: [Wallpaper]
    @ObservedObject var thumbs: ThumbnailCache
    @State private var position = 0
    private let timer = Timer.publish(every: 2.4, on: .main, in: .common).autoconnect()

    var body: some View {
        let n = max(items.count, 1)
        ZStack {
            if items.isEmpty {
                ForEach(-2...2, id: \.self) { rel in
                    card(nil, rel: rel)
                }
            } else {
                ForEach(-3...3, id: \.self) { offset in
                    let index = ((position + offset) % n + n) % n
                    card(items[index], rel: offset)
                        .id("\(position + offset)")
                }
            }
        }
        .onReceive(timer) { _ in
            guard items.count > 1, !Motion.reduced else { return }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) { position += 1 }
        }
    }

    private func card(_ item: Wallpaper?, rel: Int) -> some View {
        let h: CGFloat = 88
        let a = CGFloat(abs(rel))
        let shape = Slant(skew: h * 0.3)
        return ZStack {
            LinearGradient(colors: [Color(white: 0.18), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
            if let item, let image = thumbs.image(for: item) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: h * 0.84, height: h)
        .clipShape(shape)
        .overlay(shape.fill(Color.black.opacity(Double(min(a, 3)) * 0.15)))
        .overlay(shape.stroke(Color.white.opacity(rel == 0 ? 1 : 0), lineWidth: 2))
        .scaleEffect(rel == 0 ? 1 : 0.88)
        .offset(x: CGFloat(rel) * h * 0.5)
        .opacity(Double(max(0, 3 - a)) / 2)
        .zIndex(-Double(a))
        .transition(.opacity)
    }
}
