import AppKit
import AVFoundation
import ImageIO

enum MediaKind { case image, video }

enum Media {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func kind(of url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// Preview sized so its shorter side is at least `shortSide` pixels.
    static func thumbnail(_ url: URL, kind: MediaKind, shortSide: CGFloat) -> NSImage? {
        switch kind {
        case .image:
            guard let (w, h) = pixelSize(url) else { return decode(url, maxPixel: shortSide * 2) }
            let longest = max(w, h)
            return decode(url, maxPixel: min(longest, ceil(longest * shortSide / min(w, h))))
        case .video:
            return videoFrame(url, maxSize: CGSize(width: shortSide * 4, height: shortSide)).map(wrap)
        }
    }

    /// Image at the resolution needed to aspect-fill `target` (pixels), never upscaled.
    static func full(_ url: URL, kind: MediaKind, covering target: CGSize) -> NSImage? {
        switch kind {
        case .image:
            guard let (w, h) = pixelSize(url) else { return decode(url, maxPixel: max(target.width, target.height)) }
            let longest = max(w, h)
            return decode(url, maxPixel: min(longest, ceil(longest * max(target.width / w, target.height / h))))
        case .video:
            return videoFrame(url, maxSize: nil).map(wrap)
        }
    }

    /// First frame of a video — the same frame a live wallpaper starts on.
    static func videoFrame(_ url: URL, maxSize: CGSize?) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maxSize { generator.maximumSize = maxSize }
        let box = Box<CGImage>()
        let done = DispatchSemaphore(value: 0)
        generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
            box.value = image
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return box.value
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func pixelSize(_ url: URL) -> (CGFloat, CGFloat)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0
        else { return nil }
        return (CGFloat(w), CGFloat(h))
    }

    /// Fully decoded up front so drawing never stalls an animation.
    private static func decode(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map(wrap)
    }

    private static func wrap(_ cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T?
}

/// Loads previews on demand and keeps only a bounded number in memory,
/// so folders with hundreds of wallpapers stay light.
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    var shortSide: CGFloat = 820
    private let limit = 28
    private var images: [URL: (modified: Date, image: NSImage)] = [:]
    private var order: [URL] = []
    private var inflight: Set<URL> = []
    private var failed: Set<URL> = []
    private let queue = DispatchQueue(label: "slick.thumbnails", qos: .userInitiated, attributes: .concurrent)

    /// Safe to call from a view body: never publishes synchronously.
    func image(for item: Wallpaper) -> NSImage? {
        if let hit = images[item.url], hit.modified == item.modified {
            touch(item.url)
            return hit.image
        }
        DispatchQueue.main.async { self.load(item) }
        return nil
    }

    func prefetch(_ items: [Wallpaper]) {
        items.forEach(load)
    }

    private func touch(_ url: URL) {
        if order.last != url {
            order.removeAll { $0 == url }
            order.append(url)
        }
    }

    private func load(_ item: Wallpaper) {
        guard !inflight.contains(item.url), !failed.contains(item.url),
              images[item.url]?.modified != item.modified else { return }
        inflight.insert(item.url)
        let side = shortSide
        queue.async {
            let image = Media.thumbnail(item.url, kind: item.kind, shortSide: side)
            DispatchQueue.main.async {
                self.inflight.remove(item.url)
                guard let image else { self.failed.insert(item.url); return }
                self.objectWillChange.send()
                self.images[item.url] = (item.modified, image)
                self.touch(item.url)
                while self.order.count > self.limit {
                    self.images[self.order.removeFirst()] = nil
                }
            }
        }
    }
}
