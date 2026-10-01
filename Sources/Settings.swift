import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask
    var key: String

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey | shiftKey), key: "W")

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// Builds a shortcut from a key press; requires at least one of ⌘ ⌥ ⌃ so it can't swallow typing.
    static func from(_ e: NSEvent) -> Shortcut? {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        return Shortcut(keyCode: UInt32(e.keyCode), modifiers: m, key: keyName(e))
    }

    private static func keyName(_ e: NSEvent) -> String {
        let named: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = named[e.keyCode] { return name }
        let chars = e.characters(byApplyingModifiers: []) ?? e.charactersIgnoringModifiers ?? "?"
        return chars.uppercased()
    }
}

enum MotionSpeed: String, CaseIterable, Identifiable {
    case relaxed, standard, snappy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .relaxed: "Relaxed"
        case .standard: "Default"
        case .snappy: "Snappy"
        }
    }

    var factor: Double {
        switch self {
        case .relaxed: 1.3
        case .standard: 1
        case .snappy: 0.72
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var shortcut: Shortcut { didSet { store(shortcut, "shortcut") } }
    @Published var folderPath: String { didSet { defaults.set(folderPath, forKey: "folderPath") } }
    @Published var motion: MotionSpeed { didSet { defaults.set(motion.rawValue, forKey: "motion") } }
    @Published var loop: Bool { didSet { defaults.set(loop, forKey: "loop") } }
    @Published var reduceMotion: Bool { didSet { defaults.set(reduceMotion, forKey: "reduceMotion") } }
    @Published var shuffleMinutes: Int { didSet { defaults.set(shuffleMinutes, forKey: "shuffleMinutes") } }
    @Published var shuffleAllDesktops: Bool { didSet { defaults.set(shuffleAllDesktops, forKey: "shuffleAllDesktops") } }
    @Published var launchAtLogin: Bool { didSet { if launchAtLogin != oldValue { applyLoginItem() } } }
    @Published var loginItemError: String?
    @Published var hotKeyError: String?

    var folderURL: URL {
        URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Live (video) wallpaper per display: display ID → video path.
    var liveAssignments: [String: String] {
        get { defaults.dictionary(forKey: "liveAssignments") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "liveAssignments") }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: "hasLaunchedBefore") }
        set { defaults.set(newValue, forKey: "hasLaunchedBefore") }
    }

    static let shuffleChoices: [(minutes: Int, title: String)] = [
        (0, "Off"), (15, "Every 15 minutes"), (30, "Every 30 minutes"),
        (60, "Every hour"), (180, "Every 3 hours"), (1440, "Every day"),
    ]

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private init() {
        shortcut = (defaults.data(forKey: "shortcut")).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .standard
        folderPath = defaults.string(forKey: "folderPath") ?? "~/Wallpapers"
        motion = MotionSpeed(rawValue: defaults.string(forKey: "motion") ?? "") ?? .standard
        loop = defaults.object(forKey: "loop") as? Bool ?? true
        reduceMotion = defaults.bool(forKey: "reduceMotion")
        shuffleMinutes = defaults.integer(forKey: "shuffleMinutes")
        shuffleAllDesktops = defaults.object(forKey: "shuffleAllDesktops") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private func applyLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
    }
}

/// Central place for timing so the speed setting and Reduce Motion apply everywhere.
enum Motion {
    static var factor: Double { Settings.shared.motion.factor }
    static var reduced: Bool {
        Settings.shared.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func t(_ seconds: Double) -> Double { seconds * factor }

    static func spring(_ response: Double, _ damping: Double = 0.86) -> SwiftUIAnimation {
        reduced ? .easeInOut(duration: 0.2) : .spring(response: response * factor, dampingFraction: damping)
    }
}

import SwiftUI
typealias SwiftUIAnimation = SwiftUI.Animation
