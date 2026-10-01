import AppKit
import Carbon.HIToolbox

/// System-wide hotkey via Carbon — needs no Accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    var action: (() -> Void)?

    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        installHandler()
        unregister()
        let id = EventHotKeyID(signature: OSType(0x534C_5750), id: 1) // "SLWP"
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKeyCenter.shared.action?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
