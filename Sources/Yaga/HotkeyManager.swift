import AppKit
import Carbon.HIToolbox

/// Registers a system-wide shortcut with Carbon's hot key API, which — unlike a
/// global NSEvent monitor — does not require Accessibility permission.
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x47494641 // 'GIFA'

    private init() {}

    func start() {
        installHandlerIfNeeded()
        reregister()
    }

    func reregister() {
        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
        }
        let hotkey = Settings.shared.hotkey
        let id = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ in
                DispatchQueue.main.async { HotkeyManager.shared.onTrigger?() }
                return noErr
            },
            1, &spec, nil, &handlerRef
        )
    }
}
