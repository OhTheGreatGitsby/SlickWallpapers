import AppKit

struct Wallpaper: Identifiable, Equatable {
    let url: URL
    let name: String
    let modified: Date
    let kind: MediaKind

    var id: URL { url }
}

/// Lists the wallpapers folder and keeps the list current as files come and go.
/// Only metadata lives here; previews are loaded lazily by `ThumbnailCache`.
final class WallpaperStore: ObservableObject {
    @Published private(set) var items: [Wallpaper] = []

    private(set) var folder: URL
    private let queue = DispatchQueue(label: "slick.store", qos: .userInitiated)
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?

    init(folder: URL) {
        self.folder = folder
    }

    func use(folder: URL) {
        self.folder = folder
        ensureFolder()
        startWatching()
        refresh()
    }

    func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func startWatching() {
        watcher?.cancel()
        let fd = open(folder.path, O_EVTONLY)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func refresh(completion: (() -> Void)? = nil) {
        let folder = self.folder
        queue.async { [weak self] in
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            let list: [Wallpaper] = urls
                .compactMap { url in
                    guard let kind = Media.kind(of: url) else { return nil }
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return Wallpaper(url: url, name: Self.prettyName(url), modified: modified, kind: kind)
                }
                .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.items != list { self.items = list }
                completion?()
            }
        }
    }

    func index(ofCurrentWallpaperOn screen: NSScreen) -> Int? {
        guard let current = LiveWallpaper.shared.video(on: screen) ?? NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let path = current.resolvingSymlinksInPath().standardizedFileURL.path
        return items.firstIndex { $0.url.resolvingSymlinksInPath().standardizedFileURL.path == path }
    }

    static func prettyName(_ url: URL) -> String {
        let cleaned = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"\d{3,5}\s*x\s*\d{3,5}|\b[0-9a-f]{20,}\b|\bupscayl\b|\b\d+x\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
            .capitalized
        return cleaned.isEmpty ? url.deletingPathExtension().lastPathComponent : cleaned
    }
}
