import AppKit
import Carbon.HIToolbox

/// Registers a system-wide shortcut with Carbon's hot key API, which — unlike a
/// global NSEvent monitor — does not require Accessibility permission.
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Fires with `paste: true` when the panel was summoned by the paste
    /// shortcut, which inserts the pick instead of only copying it.
    var onTrigger: ((_ paste: Bool) -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var pasteHotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x47494641 // 'GIFA'
    private static let openID: UInt32 = 1
    private static let pasteID: UInt32 = 2

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
        if let existing = pasteHotKeyRef {
            UnregisterEventHotKey(existing)
            pasteHotKeyRef = nil
        }

        let hotkey = Settings.shared.hotkey
        RegisterEventHotKey(
            hotkey.keyCode, hotkey.modifiers,
            EventHotKeyID(signature: signature, id: Self.openID),
            GetEventDispatcherTarget(), 0, &hotKeyRef
        )

        // A paste shortcut equal to the open shortcut would register second and
        // never fire; treat that as "off" rather than silently shadowing.
        if let paste = Settings.shared.pasteHotkey, paste != hotkey {
            RegisterEventHotKey(
                paste.keyCode, paste.modifiers,
                EventHotKeyID(signature: signature, id: Self.pasteID),
                GetEventDispatcherTarget(), 0, &pasteHotKeyRef
            )
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id
                )
                let paste = id.id == HotkeyManager.pasteID
                DispatchQueue.main.async { HotkeyManager.shared.onTrigger?(paste) }
                return noErr
            },
            1, &spec, nil, &handlerRef
        )
    }
}
