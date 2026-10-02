import Accelerate
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

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

    /// A card preview: the centre of the image, cropped to `target`'s shape at exactly `target`'s
    /// pixel size — never more than a card can show, so nothing is stored that isn't drawn.
    static func thumbnail(_ url: URL, kind: MediaKind, target: CGSize) -> CGImage? {
        let source: CGImage?
        switch kind {
        case .image:
            if let (w, h) = pixelSize(url) {
                let scale = min(1, max(target.width / w, target.height / h))
                source = decode(url, maxPixel: ceil(max(w, h) * scale))
            } else {
                source = decode(url, maxPixel: max(target.width, target.height) * 2)
            }
        case .video:
            source = videoFrame(url, maxSize: CGSize(width: target.width * 4, height: target.height))
        }
        return source.flatMap { cropCenter($0, to: target) }
    }

    /// Image at the resolution needed to aspect-fill `target` (pixels), never upscaled.
    static func full(_ url: URL, kind: MediaKind, covering target: CGSize) -> CGImage? {
        switch kind {
        case .image:
            guard let (w, h) = pixelSize(url) else { return decode(url, maxPixel: max(target.width, target.height)).flatMap(native) }
            let longest = max(w, h)
            return decode(url, maxPixel: min(longest, ceil(longest * max(target.width / w, target.height / h)))).flatMap(native)
        case .video:
            return videoFrame(url, maxSize: nil).flatMap(native)
        }
    }

    /// Returns the image in the pixel layout the window server draws directly (32-bit BGRX/BGRA,
    /// little-endian), in its own colour space. Anything else is converted at draw time and the
    /// converted copy is kept in CoreGraphics' image cache — a hidden duplicate of every image.
    /// The conversion runs through vImage, which works on raw pixels and never touches that cache.
    static func native(_ image: CGImage) -> CGImage? {
        guard !isNative(image), var format = nativeFormat(for: image),
              var buffer = try? vImage_Buffer(cgImage: image, format: format) else { return image }
        defer { buffer.free() }
        return try? buffer.createCGImage(format: format)
    }

    private static func isNative(_ image: CGImage) -> Bool {
        image.bitsPerPixel == 32 && image.bitsPerComponent == 8 && image.bitmapInfo.contains(.byteOrder32Little)
            && (image.alphaInfo == .noneSkipFirst || image.alphaInfo == .premultipliedFirst)
    }

    private static func nativeFormat(for image: CGImage) -> vImage_CGImageFormat? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipFirst : .premultipliedFirst
        return vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
                                    bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
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

    /// Decodes a small file (e.g. a cached preview) fully, up front.
    static func decodeFile(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary).flatMap(native)
    }

    static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        CGImageDestinationFinalize(dest)
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
    private static func decode(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Centre crop to `target`'s aspect ratio, scaled to at most `target`, in native pixel layout.
    /// Done with vImage (high-quality resampling) into a fresh buffer, so the large source is freed.
    private static func cropCenter(_ image: CGImage, to target: CGSize) -> CGImage? {
        guard var format = nativeFormat(for: image),
              var source = try? vImage_Buffer(cgImage: image, format: format) else { return nil }
        defer { source.free() }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let aspect = target.width / target.height
        var cw = w, ch = h
        if w / h > aspect { cw = (h * aspect).rounded() } else { ch = (w / aspect).rounded() }
        let x = Int(((w - cw) / 2).rounded()), y = Int(((h - ch) / 2).rounded())
        var region = vImage_Buffer(data: source.data.advanced(by: y * source.rowBytes + x * 4),
                                   height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: source.rowBytes)
        let outW = Int(min(cw, target.width).rounded()), outH = Int(min(ch, target.height).rounded())
        guard outW > 0, outH > 0,
              var output = try? vImage_Buffer(width: outW, height: outH, bitsPerPixel: 32) else { return nil }
        defer { output.free() }
        guard vImageScale_ARGB8888(&region, &output, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { return nil }
        return try? output.createCGImage(format: format)
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T?
}

/// Card previews, loaded on demand.
///
/// Memory: only a small, bounded set lives in RAM, and only while the selector (or Settings) is
/// open — `purge()` drops it all when they close. Finished previews are kept on disk as small
/// JPEGs, so reopening decodes a few hundred KB instead of re-reading multi-megabyte originals.
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    /// Pixel size of a preview: a focused card's height, with a square crop that covers the card
    /// plus its parallax margin. Set from the screen the selector opens on.
    private(set) var target = CGSize(width: 800, height: 800)

    private let limit = 16
    private var images: [URL: (modified: Date, image: CGImage)] = [:]
    private var order: [URL] = []
    private var inflight: Set<URL> = []
    private var failed: Set<URL> = []
    private var waiters: [(urls: Set<URL>, done: () -> Void)] = []
    private let queue = DispatchQueue(label: "slick.thumbnails", qos: .userInitiated, attributes: .concurrent)
    private let warmQueue = DispatchQueue(label: "slick.thumbnails.warm", qos: .utility)
    /// Decoding originals is the expensive part (a 4K PNG briefly needs ~30 MB); keep it to two at once.
    private let decodeSlots = DispatchSemaphore(value: 2)
    private let diskFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SlickWallpapers/Previews", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(at: diskFolder, withIntermediateDirectories: true)
    }

    /// Previews are sized for the card height on `screen`, rounded up in steps so the
    /// on-disk cache is shared between similar displays.
    func configure(for screen: NSScreen) {
        let needed = screen.pixelSize.height * 0.47
        let side = (needed / 100).rounded(.up) * 100
        let size = CGSize(width: side, height: side)
        if size != target {
            target = size
            images.removeAll()
            order.removeAll()
        }
    }

    /// Safe to call from a view body: never publishes synchronously.
    func image(for item: Wallpaper) -> CGImage? {
        if let hit = images[item.url], hit.modified == item.modified {
            touch(item.url)
            return hit.image
        }
        DispatchQueue.main.async { self.load(item) }
        return nil
    }

    /// Loads `items`, calling `done` once all of them are in memory (or failed).
    func prefetch(_ items: [Wallpaper], done: (() -> Void)? = nil) {
        items.forEach(load)
        guard let done else { return }
        let pending = Set(items.filter { images[$0.url]?.modified != $0.modified && !failed.contains($0.url) }.map(\.url))
        if pending.isEmpty { done() } else { waiters.append((pending, done)) }
    }

    /// Drops every in-memory preview. Disk copies stay for the next open.
    func purge() {
        objectWillChange.send()
        images.removeAll()
        order.removeAll()
        failed.removeAll()
    }

    /// Makes sure every wallpaper has a preview on disk (so the first open is instant too)
    /// and deletes previews of files that are gone. Runs at low priority, keeps nothing in RAM.
    func warmDisk(_ items: [Wallpaper]) {
        let size = target
        warmQueue.async { [self] in
            var keep: Set<String> = []
            for item in items {
                let file = diskURL(item, size: size)
                keep.insert(file.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: file.path) else { continue }
                autoreleasepool { _ = render(item, size: size) }
            }
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: diskFolder.path)) ?? []
            for name in existing where !keep.contains(name) && name.hasSuffix("-\(Int(size.height)).jpg") {
                try? FileManager.default.removeItem(at: diskFolder.appendingPathComponent(name))
            }
        }
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
        let size = target
        queue.async { [self] in
            let image = autoreleasepool { () -> CGImage? in
                let file = diskURL(item, size: size)
                return Media.decodeFile(file) ?? render(item, size: size)
            }
            DispatchQueue.main.async { [self] in
                inflight.remove(item.url)
                if let image, size == target {
                    objectWillChange.send()
                    images[item.url] = (item.modified, image)
                    touch(item.url)
                    while order.count > limit {
                        images[order.removeFirst()] = nil
                    }
                } else if image == nil {
                    failed.insert(item.url)
                }
                resolveWaiters(item.url)
            }
        }
    }

    private func resolveWaiters(_ url: URL) {
        var ready: [() -> Void] = []
        waiters = waiters.compactMap { waiter in
            var w = waiter
            w.urls.remove(url)
            if w.urls.isEmpty { ready.append(w.done); return nil }
            return w
        }
        ready.forEach { $0() }
    }

    /// Builds a preview from the original and stores it on disk.
    private func render(_ item: Wallpaper, size: CGSize) -> CGImage? {
        decodeSlots.wait()
        defer { decodeSlots.signal() }
        guard let image = Media.thumbnail(item.url, kind: item.kind, target: size) else { return nil }
        Media.writeJPEG(image, to: diskURL(item, size: size))
        return image
    }

    private func diskURL(_ item: Wallpaper, size: CGSize) -> URL {
        // FNV-1a over path + modification date: changes whenever the file does.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(item.url.path)|\(item.modified.timeIntervalSince1970)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return diskFolder.appendingPathComponent(String(hash, radix: 16) + "-\(Int(size.height)).jpg")
    }
}

/// Hands memory freed by `purge()` and closed windows back to the system right away.
func releaseFreedMemory() {
    malloc_zone_pressure_relief(nil, 0)
}
