import AppKit
import ImageIO

struct Wallpaper: Identifiable, Equatable {
    let url: URL
    let name: String
    let modified: Date
    let thumbnail: NSImage

    var id: URL { url }

    static func == (a: Wallpaper, b: Wallpaper) -> Bool {
        a.url == b.url && a.modified == b.modified
    }
}

enum ImageLoader {
    /// Decodes a downsampled, fully-rasterised image so drawing never stalls the animation.
    static func thumbnail(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Loads the image at the resolution needed to aspect-fill `target` (in pixels), never upscaling.
    static func full(_ url: URL, covering target: CGSize) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let ph = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pw > 0, ph > 0
        else { return thumbnail(url, maxPixel: max(target.width, target.height)) }
        let longest = max(pw, ph)
        let scale = max(target.width / pw, target.height / ph)
        return thumbnail(url, maxPixel: min(longest, ceil(longest * scale)))
    }
}

final class WallpaperStore: ObservableObject {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Wallpapers", isDirectory: true)
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]

    @Published private(set) var items: [Wallpaper] = []

    private let queue = DispatchQueue(label: "wallpaper.store", qos: .userInitiated)
    private var cache: [URL: Wallpaper] = [:] // only touched on `queue`
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?

    func ensureFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    }

    func startWatching() {
        let fd = open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleRefresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func refresh(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            let files = urls
                .filter { Self.extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let dates = files.map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }

            let cached = self.cache
            var loaded = [Wallpaper?](repeating: nil, count: files.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                let url = files[i]
                var item = cached[url]
                if item?.modified != dates[i] {
                    item = ImageLoader.thumbnail(url, maxPixel: 1400).map {
                        Wallpaper(url: url, name: Self.prettyName(url), modified: dates[i], thumbnail: $0)
                    }
                }
                lock.lock(); loaded[i] = item; lock.unlock()
            }
            let list = loaded.compactMap { $0 }
            self.cache = Dictionary(uniqueKeysWithValues: list.map { ($0.url, $0) })

            DispatchQueue.main.async {
                if self.items != list { self.items = list }
                completion?()
            }
        }
    }

    func index(ofCurrentWallpaperOn screen: NSScreen) -> Int? {
        guard let current = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let path = current.resolvingSymlinksInPath().standardizedFileURL.path
        return items.firstIndex { $0.url.resolvingSymlinksInPath().standardizedFileURL.path == path }
    }

    static func prettyName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"\d{3,5}\s*x\s*\d{3,5}|\b[0-9a-f]{20,}\b|\bupscayl\b|\b\d+x\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
            .capitalized
    }
}
