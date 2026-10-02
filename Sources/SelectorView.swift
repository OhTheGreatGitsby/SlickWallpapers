import SwiftUI

enum Phase { case browsing, applying }

struct MenuItem: Identifiable, Equatable {
    enum Action { case allDesktops, thisDisplay, reveal, trash }
    let action: Action
    let title: String
    let icon: String
    var destructive = false
    var id: String { title }
}

final class SelectorModel: ObservableObject {
    @Published var items: [Wallpaper] = []
    /// Unbounded while looping; the selected item is `position mod count`.
    @Published var position = 0
    @Published var wraps = false
    @Published var appeared = false
    @Published var phase: Phase = .browsing
    @Published var nudge: CGFloat = 0
    @Published var menu: [MenuItem] = []
    @Published var menuOpen = false
    @Published var menuIndex = 0
    @Published var query = ""
    @Published var libraryEmpty = false
    @Published var fullURL: URL?
    @Published var fullImage: CGImage?
    @Published var trashing: URL?
    @Published var badge: String?
    @Published var reduced = false
    @Published var settled = false
    @Published var spinning = false

    var selectedIndex: Int? {
        let n = items.count
        guard n > 0 else { return nil }
        return wraps ? ((position % n) + n) % n : min(max(position, 0), n - 1)
    }

    var selected: Wallpaper? { selectedIndex.map { items[$0] } }

    /// Cards within reach of the centre. When looping, the same wallpaper can appear more
    /// than once (one copy per lap), each with a stable id so the row scrolls seamlessly.
    var entries: [CardEntry] {
        let n = items.count
        guard n > 0 else { return [] }
        let reach = 5
        if !wraps {
            let pos = min(max(position, 0), n - 1)
            return items.indices.compactMap { i in
                let rel = i - pos
                return abs(rel) <= reach ? CardEntry(id: items[i].url.path, item: items[i], rel: rel) : nil
            }
        }
        var out: [CardEntry] = []
        for i in 0..<n {
            let lo = Int((Double(position - reach - i) / Double(n)).rounded(.up))
            let hi = Int((Double(position + reach - i) / Double(n)).rounded(.down))
            guard lo <= hi else { continue }
            for lap in lo...hi {
                out.append(CardEntry(id: "\(items[i].url.path)#\(lap)", item: items[i], rel: i + lap * n - position))
            }
        }
        return out
    }
}

struct CardEntry: Identifiable {
    let id: String
    let item: Wallpaper
    let rel: Int
}

struct SelectorActions {
    var tap: (Int) -> Void
    var dismiss: () -> Void
    var runMenu: (Int) -> Void
    var hoverMenu: (Int) -> Void
    var openFolder: () -> Void
}

/// Parallelogram leaning like "\" — the skew animates down to 0 for the fullscreen morph.
struct Slant: Shape {
    var skew: CGFloat
    var animatableData: CGFloat {
        get { skew }
        set { skew = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - skew, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + skew, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct CardLayout {
    var w: CGFloat, h: CGFloat, skew: CGFloat
    var x: CGFloat, y: CGFloat, scale: CGFloat
    var opacity: Double, blur: CGFloat, dim: Double, border: Double, shadow: Double
    var margin: CGFloat, parallax: CGFloat, rotation: Double, z: Double
}

/// Muted looping preview inside the focused card, masked to the same slant.
private struct CardVideo: NSViewRepresentable {
    let url: URL
    let skew: CGFloat

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView(url: url, fadeDuration: 0.45)
        view.skew = skew
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) { view.skew = skew }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) { view.stop() }
}

private struct Placeholder: View {
    var body: some View {
        LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct CardView: View {
    let item: Wallpaper
    let image: CGImage?
    let l: CardLayout
    let playVideo: Bool

    var body: some View {
        let shape = Slant(skew: l.skew)
        let extra = l.w * l.margin
        ZStack {
            if image == nil {
                Placeholder().transition(.opacity)
            }
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: l.w + extra, height: l.h)
                    .offset(x: l.parallax * extra / 2)
                    .transition(.opacity)
            }
            if playVideo {
                CardVideo(url: item.url, skew: l.skew)
                    .frame(width: l.w, height: l.h)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.35), value: image != nil)
        .frame(width: l.w, height: l.h)
        .clipShape(shape)
        .overlay(shape.fill(Color.black.opacity(l.dim)))
        .overlay(alignment: .topLeading) {
            if item.kind == .video {
                LiveTag()
                    .padding(.top, 14)
                    .padding(.leading, 18)
                    .opacity(l.border > 0.5 ? 1 : 0.75)
                    .opacity(l.margin > 0.001 || l.border > 0 ? 1 : 0)
            }
        }
        .overlay(shape.stroke(Color.white.opacity(l.border), lineWidth: 4.5))
        .background {
            if l.shadow > 0.01 {
                shape.fill(Color.black.opacity(0.5 * l.shadow))
                    .blur(radius: 22)
                    .offset(y: 16)
            }
        }
        .contentShape(shape)
    }
}

private struct LiveTag: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
                .opacity(pulse ? 1 : 0.35)
            Text("LIVE").font(.system(size: 9.5, weight: .heavy)).tracking(1.2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.45)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct SelectorView: View {
    @ObservedObject var model: SelectorModel
    @ObservedObject var thumbs: ThumbnailCache
    let actions: SelectorActions
    @Namespace private var menuSpace

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                backdrop
                    .contentShape(Rectangle())
                    .onTapGesture { actions.dismiss() }

                if model.items.isEmpty {
                    emptyState
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    ForEach(model.entries) { entry in
                        card(entry, size)
                    }
                    caption(size)
                    menu(size)
                }
                if model.reduced, let image = model.fullImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .opacity(model.phase == .applying ? 1 : 0)
                        .animation(.easeInOut(duration: 0.45), value: model.phase == .applying)
                        .allowsHitTesting(false)
                }
                searchField(size)
                badge(size)
                hints(size)
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var browsing: Bool { model.appeared && model.phase == .browsing }

    // MARK: Layout

    private func layout(_ entry: CardEntry, _ size: CGSize) -> CardLayout {
        let W = size.width, H = size.height
        let rel = CGFloat(entry.rel)
        let a = abs(rel), sign: CGFloat = rel < 0 ? -1 : 1
        let h = H * 0.46
        let isSel = entry.rel == 0

        var l = CardLayout(
            w: h * 0.84, h: h, skew: h * 0.30,
            x: rel * h * 0.54 + sign * min(a, 1) * h * 0.05 + model.nudge,
            y: -H * 0.03,
            scale: isSel ? 1 : 0.9,
            opacity: Double(min(max(4.5 - a, 0), 1)),
            blur: model.spinning ? 2.5 : 0,
            dim: Double(min(a, 3)) * 0.13,
            border: isSel ? 1 : 0,
            shadow: a <= 1 ? 1 : 0,
            margin: 0.16 * min(a, 1),
            parallax: min(max(-rel * 0.45, -1), 1),
            rotation: 0,
            z: isSel ? 100 : -Double(a)
        )

        if model.menuOpen && model.phase == .browsing {
            l.y -= H * 0.09
            if isSel { l.scale = 1.0 } else { l.dim = min(l.dim + 0.25, 0.65); l.y += H * 0.015; l.scale *= 0.96 }
        }

        if entry.item.url == model.trashing {
            l.y += H * 0.42
            l.scale *= 0.78
            l.opacity = 0
            l.blur = 8
            l.rotation = -7
            l.border = 0
        }

        if model.phase == .applying {
            if model.reduced {
                l.opacity = 0
            } else if isSel {
                l.w = W; l.h = H; l.skew = 0
                l.x = 0; l.y = 0; l.scale = 1
                l.dim = 0; l.border = 0; l.shadow = 0
                l.margin = 0; l.parallax = 0; l.z = 1000; l.blur = 0
            } else {
                l.x += sign * W * 0.55
                l.scale *= 0.86
                l.opacity = 0
                l.blur = 14
            }
        } else if !model.appeared {
            if model.reduced {
                l.opacity = 0
            } else {
                l.x *= 0.55
                l.y += H * 0.11
                l.scale *= 0.9
                l.opacity = 0
                l.blur = 10
            }
        }
        return l
    }

    private func card(_ entry: CardEntry, _ size: CGSize) -> some View {
        let l = layout(entry, size)
        let isSel = entry.rel == 0
        let full = isSel && model.fullURL == entry.item.url ? model.fullImage : nil
        let image = full ?? thumbs.image(for: entry.item)
        let playVideo = isSel && entry.item.kind == .video && browsing && model.settled && !model.reduced
        let stagger = model.reduced ? 0 : 0.045 * Double(min(abs(entry.rel), 6))
        let f = Motion.factor
        return CardView(item: entry.item, image: image, l: l, playVideo: playVideo)
            .scaleEffect(l.scale)
            .rotationEffect(.degrees(l.rotation))
            .blur(radius: l.blur)
            .opacity(l.opacity)
            .offset(x: l.x, y: l.y)
            .zIndex(l.z)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .animation(
                model.appeared
                    ? (model.reduced ? .easeOut(duration: 0.25) : .spring(response: 0.62 * f, dampingFraction: 0.84).delay(stagger * f))
                    : .easeIn(duration: 0.22 * f).delay(stagger * 0.4 * f),
                value: model.appeared
            )
            .allowsHitTesting(browsing && l.opacity > 0.05)
            .onTapGesture { actions.tap(entry.rel) }
    }

    // MARK: Chrome

    private var backdrop: some View {
        ZStack {
            Color.black.opacity(0.22)
            RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 120, endRadius: 1100)
            Color.black.opacity(model.menuOpen ? 0.18 : 0)
        }
        .opacity(browsing ? 1 : 0)
        .animation(.easeOut(duration: Motion.t(model.phase == .applying ? 0.5 : 0.35)), value: browsing)
        .animation(.easeOut(duration: 0.3), value: model.menuOpen)
    }

    private func caption(_ size: CGSize) -> some View {
        let H = size.height
        let shown = browsing && !model.menuOpen && model.selected != nil
        return ZStack {
            if let item = model.selected {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        if item.kind == .video {
                            Image(systemName: "play.circle.fill").font(.system(size: 13)).opacity(0.8)
                        }
                        Text(item.name)
                            .font(.system(size: 15, weight: .semibold))
                            .tracking(0.4)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: size.width * 0.5)
                    Text(String(format: "%02d  ·  %02d", (model.selectedIndex ?? 0) + 1, model.items.count))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.5)
                        .opacity(0.55)
                }
                .id(item.id)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 10)),
                    removal: .opacity.combined(with: .offset(y: -6))
                ))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 10, y: 2)
        .offset(y: H * 0.20 + 52)
        .opacity(shown ? 1 : 0)
        .blur(radius: model.menuOpen ? 6 : 0)
        .offset(y: shown ? 0 : 14)
        .animation(Motion.spring(0.5, 0.9).delay(shown ? Motion.t(0.12) : 0), value: shown)
        .allowsHitTesting(false)
    }

    private func menu(_ size: CGSize) -> some View {
        let H = size.height
        let shown = browsing && model.menuOpen
        return VStack(spacing: 6) {
            ForEach(Array(model.menu.enumerated()), id: \.element.id) { idx, item in
                let focused = idx == model.menuIndex
                HStack(spacing: 11) {
                    Image(systemName: item.icon)
                        .font(.system(size: 13.5, weight: .semibold))
                        .frame(width: 18)
                    Text(item.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .tracking(0.15)
                    Spacer(minLength: 0)
                    Text("↩")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .frame(width: 22, height: 19)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.1)))
                        .opacity(focused ? 1 : 0)
                }
                .foregroundStyle(focused ? (item.destructive ? Color(red: 0.86, green: 0.16, blue: 0.2) : Color.black.opacity(0.88)) : Color.white.opacity(0.92))
                .padding(.leading, 16)
                .padding(.trailing, 9)
                .frame(width: 270, height: 38)
                .background {
                    if focused {
                        Capsule().fill(.white)
                            .shadow(color: .white.opacity(0.3), radius: 16)
                            .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                            .matchedGeometryEffect(id: "focus", in: menuSpace)
                    } else {
                        Capsule().fill(.white.opacity(0.08))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                    }
                }
                .contentShape(Capsule())
                .onTapGesture { actions.runMenu(idx) }
                .onHover { if $0 { actions.hoverMenu(idx) } }
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 18 + CGFloat(idx) * 6)
                .blur(radius: shown ? 0 : 6)
                .animation(Motion.spring(0.48, 0.82).delay(shown ? Motion.t(0.03 * Double(idx)) : 0), value: shown)
            }
        }
        .offset(y: H * 0.20 - H * 0.09 + 30 + CGFloat(model.menu.count) * 22)
        .allowsHitTesting(shown)
    }

    private func searchField(_ size: CGSize) -> some View {
        let shown = browsing && !model.query.isEmpty
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .opacity(0.7)
            Text(model.query.isEmpty ? " " : model.query)
                .font(.system(size: 17, weight: .medium))
                .lineLimit(1)
            if shown { Caret() }
            if !model.items.isEmpty || !model.query.isEmpty {
                Text("\(model.items.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 46)
        .frame(minWidth: 220)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .offset(y: -size.height / 2 + 86)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.9)
        .offset(y: shown ? 0 : -20)
        .animation(Motion.spring(0.45, 0.82), value: shown)
        .animation(Motion.spring(0.3, 0.9), value: model.query)
        .allowsHitTesting(false)
    }

    private func badge(_ size: CGSize) -> some View {
        let shown = model.phase == .applying && model.badge != nil
        return HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
            Text(model.badge ?? "")
                .font(.system(size: 13.5, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .offset(y: size.height / 2 - 70)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 26)
        .animation(Motion.spring(0.5, 0.82).delay(shown ? Motion.t(0.55) : 0), value: shown)
        .allowsHitTesting(false)
    }

    private func hints(_ size: CGSize) -> some View {
        HStack(spacing: 18) {
            if model.menuOpen {
                hint(["↑", "↓"], "Choose")
                hint(["↩"], "Select")
                hint(["esc"], "Back")
            } else if model.items.isEmpty && model.libraryEmpty {
                hint(["⌘O"], "Open Folder")
                hint(["esc"], "Close")
            } else {
                hint(["←", "→"], "Browse")
                hint(["↩"], "Apply")
                hint(["↓"], "More")
                hint(["space"], "Shuffle")
                hint(["A–Z"], "Search")
                hint(["esc"], model.query.isEmpty ? "Close" : "Clear")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .offset(y: size.height / 2 - 54)
        .opacity(browsing ? 1 : 0)
        .offset(y: browsing ? 0 : 20)
        .animation(Motion.spring(0.55, 0.9).delay(browsing ? Motion.t(0.25) : 0), value: browsing)
        .animation(.easeInOut(duration: 0.2), value: model.menuOpen)
        .allowsHitTesting(false)
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 19)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.14)))
            }
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .opacity(0.7)
        }
        .foregroundStyle(.white)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: model.libraryEmpty ? "photo.on.rectangle.angled" : "magnifyingglass")
                .font(.system(size: 42, weight: .light))
                .opacity(0.8)
            Text(model.libraryEmpty ? "No wallpapers yet" : "No matches")
                .font(.system(size: 20, weight: .semibold))
            Text(model.libraryEmpty
                 ? "Drop images or videos into \(Settings.shared.folderPath) and they show up here."
                 : "Nothing is called “\(model.query)”. Press esc to clear.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .opacity(0.65)
            if model.libraryEmpty {
                Button("Open Folder", action: actions.openFolder)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: 380)
        .foregroundStyle(.white)
        .padding(40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .opacity(browsing ? 1 : 0)
        .scaleEffect(browsing ? 1 : 0.94)
        .animation(Motion.spring(0.5, 0.85), value: browsing)
    }
}

private struct Caret: View {
    @State private var on = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.white)
            .frame(width: 2, height: 20)
            .opacity(on ? 0.9 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { on = false }
            }
    }
}
