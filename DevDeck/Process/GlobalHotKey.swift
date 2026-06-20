import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey via Carbon `RegisterEventHotKey` — fires even when DevDeck is in the
/// background, and (unlike a CGEventTap) needs no Accessibility permission. Default chord: ⌃⌥D.
@MainActor
final class GlobalHotKey {
    // The Carbon handler is a context-free C callback, so the trigger is reached via a static.
    nonisolated(unsafe) private static var fire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Returns nil if the OS refused to install the handler or register the chord.
    init?(keyCode: UInt32, modifiers: UInt32, onPress: @escaping () -> Void) {
        GlobalHotKey.fire = onPress

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { GlobalHotKey.fire?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x44564B59), id: 1)   // 'DVKY'
        let registered = RegisterEventHotKey(keyCode, modifiers, id,
                                             GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        GlobalHotKey.fire = nil
    }
}

/// Owns the lifecycle of the popover-toggle hotkey. `onTrigger` is wired once (by the AppDelegate,
/// after the menu bar exists); the Settings toggle flips `setEnabled` on/off at runtime.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()
    private init() {}

    /// What the hotkey does — set by the AppDelegate to toggle the popover.
    var onTrigger: (() -> Void)?

    private var hotKey: GlobalHotKey?

    /// Default chord ⌃⌥D (kVK_ANSI_D = 0x02, Carbon controlKey | optionKey).
    func setEnabled(_ on: Bool) {
        if on {
            guard hotKey == nil else { return }
            hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_D),
                                  modifiers: UInt32(controlKey | optionKey)) { [weak self] in
                self?.onTrigger?()
            }
            if hotKey == nil {
                DiagnosticLog.shared.log("Global hotkey ⌃⌥D could not be registered", level: .warn)
            }
        } else {
            hotKey?.unregister()
            hotKey = nil
        }
    }
}
