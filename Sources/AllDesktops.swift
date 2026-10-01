import Foundation

/// macOS only exposes "set wallpaper for the current Space". The per-Space choices live in
/// WallpaperAgent's store, so to cover every desktop we copy the entry the system just wrote
/// for the current Space into every Space/display slot, then restart the agent to reload it.
enum AllDesktops {
    private static let store = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    /// Call after `NSWorkspace.setDesktopImageURL` has been issued for the current Space.
    /// Polls briefly until the agent has persisted that choice, then propagates it.
    static func propagate(_ image: URL, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = false
            for _ in 0..<12 {
                if patch(image) { ok = true; break }
                Thread.sleep(forTimeInterval: 0.15)
            }
            if ok { restartAgent() }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    private static func patch(_ image: URL) -> Bool {
        guard let data = try? Data(contentsOf: store),
              var root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return false }

        // Template: a Desktop entry the agent already wrote for this image (has the exact format it expects).
        guard var template = findDesktop(in: root, matching: image) else { return false }
        let now = Date()
        template["LastSet"] = now
        template["LastUse"] = now

        root = replaceDesktops(in: root, with: template) as! [String: Any]
        guard let out = try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0) else { return false }
        return (try? out.write(to: store, options: .atomic)) != nil
    }

    private static func findDesktop(in node: Any, matching image: URL) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if let desktop = dict["Desktop"] as? [String: Any], points(desktop, to: image) { return desktop }
            for value in dict.values { if let hit = findDesktop(in: value, matching: image) { return hit } }
        } else if let array = node as? [Any] {
            for value in array { if let hit = findDesktop(in: value, matching: image) { return hit } }
        }
        return nil
    }

    private static func points(_ desktop: [String: Any], to image: URL) -> Bool {
        guard let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let config = choices.first?["Configuration"] as? Data,
              let decoded = try? PropertyListSerialization.propertyList(from: config, options: [], format: nil) as? [String: Any],
              let url = decoded["url"] as? [String: Any],
              let relative = url["relative"] as? String,
              let stored = URL(string: relative)
        else { return false }
        return stored.standardizedFileURL.path == image.standardizedFileURL.path
    }

    private static func replaceDesktops(in node: Any, with template: [String: Any]) -> Any {
        if var dict = node as? [String: Any] {
            for (key, value) in dict {
                dict[key] = key == "Desktop" ? template : replaceDesktops(in: value, with: template)
            }
            return dict
        }
        if let array = node as? [Any] { return array.map { replaceDesktops(in: $0, with: template) } }
        return node
    }

    private static func restartAgent() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["WallpaperAgent"]
        try? p.run()
        p.waitUntilExit()
    }
}
