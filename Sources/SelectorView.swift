import SwiftUI

enum Phase { case browsing, applying }

final class SelectorModel: ObservableObject {
    @Published var selected = 0
    @Published var appeared = false
    @Published var phase: Phase = .browsing
    @Published var nudge: CGFloat = 0
    @Published var showOptions = false
    @Published var allDesktops = false
    @Published var fullURL: URL?
    @Published var fullImage: NSImage?
}

struct SelectorActions {
    var tap: (Int) -> Void
    var dismiss: () -> Void
    var applyAll: () -> Void
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

private struct CardLayout {
    var w: CGFloat, h: CGFloat, skew: CGFloat
    var x: CGFloat, y: CGFloat, scale: CGFloat
    var opacity: Double, blur: CGFloat, dim: Double, border: Double, shadow: Double
    var margin: CGFloat, parallax: CGFloat, z: Double
}

private struct CardView: View {
    let image: NSImage
    let l: CardLayout

    var body: some View {
        let shape = Slant(skew: l.skew)
        let extra = l.w * l.margin
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: l.w + extra, height: l.h)
            .offset(x: l.parallax * extra / 2)
            .frame(width: l.w, height: l.h)
            .clipShape(shape)
            .overlay(shape.fill(Color.black.opacity(l.dim)))
            .overlay(shape.stroke(Color.white.opacity(l.border), lineWidth: 4.5))
            .compositingGroup()
            .shadow(color: .black.opacity(0.55 * l.shadow), radius: 26 * l.shadow, x: 0, y: 16 * l.shadow)
            .contentShape(shape)
    }
}

struct SelectorView: View {
    @ObservedObject var model: SelectorModel
    @ObservedObject var store: WallpaperStore
    let actions: SelectorActions

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                backdrop
                    .contentShape(Rectangle())
                    .onTapGesture { actions.dismiss() }

                if store.items.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { i, item in
                        card(i, item, size)
                    }
                    caption(size)
                    options(size)
                }
                allDesktopsBadge(size)
                hints(size)
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var selected: Int { min(max(model.selected, 0), max(store.items.count - 1, 0)) }
    private var browsing: Bool { model.appeared && model.phase == .browsing }

    // MARK: Layout

    private func layout(_ i: Int, _ size: CGSize) -> CardLayout {
        let W = size.width, H = size.height
        let rel = CGFloat(i - selected)
        let a = abs(rel), sign: CGFloat = rel < 0 ? -1 : 1
        let h = H * 0.46
        let isSel = i == selected

        var l = CardLayout(
            w: h * 0.84, h: h, skew: h * 0.30,
            x: rel * h * 0.54 + sign * min(a, 1) * h * 0.05 + model.nudge,
            y: -H * 0.03,
            scale: isSel ? 1 : 0.9,
            opacity: Double(min(max(4.5 - a, 0), 1)),
            blur: 0,
            dim: Double(min(a, 3)) * 0.13,
            border: isSel ? 1 : 0,
            shadow: 1,
            margin: 0.16,
            parallax: min(max(-rel * 0.45, -1), 1),
            z: isSel ? 100 : -Double(a)
        )

        if model.showOptions && model.phase == .browsing {
            l.y -= H * 0.045
            if isSel { l.scale = 1.02 } else { l.dim = min(l.dim + 0.22, 0.6); l.y += H * 0.01 }
        }

        if model.phase == .applying {
            if isSel {
                l.w = W; l.h = H; l.skew = 0
                l.x = 0; l.y = 0; l.scale = 1
                l.dim = 0; l.border = 0; l.shadow = 0
                l.margin = 0; l.parallax = 0; l.z = 1000
            } else {
                l.x += sign * W * 0.55
                l.scale *= 0.86
                l.opacity = 0
                l.blur = 14
            }
        } else if !model.appeared {
            l.x *= 0.55
            l.y += H * 0.11
            l.scale *= 0.9
            l.opacity = 0
            l.blur = 10
        }
        return l
    }

    @ViewBuilder
    private func card(_ i: Int, _ item: Wallpaper, _ size: CGSize) -> some View {
        let l = layout(i, size)
        let image = (model.fullURL == item.url ? model.fullImage : nil) ?? item.thumbnail
        let stagger = 0.045 * Double(min(abs(i - selected), 6))
        CardView(image: image, l: l)
            .scaleEffect(l.scale)
            .blur(radius: l.blur)
            .opacity(l.opacity)
            .offset(x: l.x, y: l.y)
            .zIndex(l.z)
            .animation(
                model.appeared
                    ? .spring(response: 0.62, dampingFraction: 0.84).delay(stagger)
                    : .easeIn(duration: 0.22).delay(stagger * 0.4),
                value: model.appeared
            )
            .allowsHitTesting(browsing && l.opacity > 0.05)
            .onTapGesture { actions.tap(i) }
    }

    // MARK: Chrome

    private var backdrop: some View {
        ZStack {
            Color.black.opacity(0.22)
            RadialGradient(
                colors: [.clear, .black.opacity(0.55)],
                center: .center, startRadius: 120, endRadius: 1100
            )
        }
        .opacity(browsing ? 1 : 0)
        .animation(.easeOut(duration: model.phase == .applying ? 0.5 : 0.35), value: browsing)
    }

    private func caption(_ size: CGSize) -> some View {
        let item = store.items[selected]
        let H = size.height
        return ZStack {
            VStack(spacing: 8) {
                Text(item.name)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(0.4)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: size.width * 0.5)
                Text(String(format: "%02d  ·  %02d", selected + 1, store.items.count))
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
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 10, y: 2)
        .offset(y: H * 0.23 - H * 0.03 + 52)
        .opacity(browsing && !model.showOptions ? 1 : 0)
        .blur(radius: model.showOptions ? 6 : 0)
        .offset(y: browsing ? 0 : 14)
        .animation(.spring(response: 0.5, dampingFraction: 0.9).delay(browsing ? 0.18 : 0), value: browsing)
        .allowsHitTesting(false)
    }

    private func hints(_ size: CGSize) -> some View {
        HStack(spacing: 18) {
            if model.showOptions {
                hint(["↩"], "Apply to All")
                hint(["↑"], "Back")
            } else {
                hint(["←", "→"], "Browse")
                hint(["↩"], "Apply")
                hint(["↓"], "More")
            }
            hint(["O"], "Folder")
            hint(["esc"], "Close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
        .offset(y: size.height / 2 - 54)
        .opacity(browsing ? 1 : 0)
        .offset(y: browsing ? 0 : 20)
        .animation(.spring(response: 0.55, dampingFraction: 0.9).delay(browsing ? 0.25 : 0), value: browsing)
        .allowsHitTesting(false)
    }

    private func options(_ size: CGSize) -> some View {
        let H = size.height
        let shown = browsing && model.showOptions
        return VStack(spacing: 10) {
            Button(action: actions.applyAll) {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Apply to All Desktops")
                        .font(.system(size: 14.5, weight: .semibold))
                        .tracking(0.2)
                    Text("↩")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .frame(width: 22, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.12)))
                }
                .foregroundStyle(.black.opacity(0.88))
                .padding(.leading, 18)
                .padding(.trailing, 10)
                .padding(.vertical, 11)
                .background(Capsule().fill(.white))
                .shadow(color: .white.opacity(0.35), radius: 18)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            Text("Every Space on every display")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.3)
                .foregroundStyle(.white.opacity(0.6))
                .shadow(color: .black.opacity(0.6), radius: 8)
        }
        .offset(y: H * 0.23 - H * 0.03 + 50)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.92)
        .offset(y: shown ? 0 : 22)
        .blur(radius: shown ? 0 : 8)
        .allowsHitTesting(shown)
    }

    private func allDesktopsBadge(_ size: CGSize) -> some View {
        let shown = model.phase == .applying && model.allDesktops
        return HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
            Text("Applied to all desktops")
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
        .animation(.spring(response: 0.5, dampingFraction: 0.82).delay(shown ? 0.55 : 0), value: shown)
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
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .opacity(0.8)
            Text("No wallpapers yet")
                .font(.system(size: 20, weight: .semibold))
            Text("Drop images into ~/Wallpapers and they show up here.")
                .font(.system(size: 13))
                .opacity(0.65)
            Button("Open Folder", action: actions.openFolder)
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
        .foregroundStyle(.white)
        .padding(40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .opacity(model.appeared ? 1 : 0)
        .scaleEffect(model.appeared ? 1 : 0.94)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: model.appeared)
    }
}
