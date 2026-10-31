import AppKit

/// One suppressing event tap owns both down and up events, including key repeats.
/// Unsupported cursor targets are swallowed too, so macOS cannot change a different screen.
@MainActor final class BrightnessKeys {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let onPress: (Bool, Bool) -> Void
    init(onPress: @escaping (Bool, Bool) -> Void) { self.onPress = onPress }
    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask: CGEventMask = 1 << 14 // NX_SYSDEFINED
        tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<BrightnessKeys>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard let native = NSEvent(cgEvent: event), native.type == .systemDefined,
                      native.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
                let key = (native.data1 >> 16) & 0xffff
                guard key == 2 || key == 3 else { return Unmanaged.passUnretained(event) }
                if (native.data1 >> 8) & 0xff == 0x0a {
                    owner.onPress(key == 2, native.modifierFlags.contains([.shift, .option]))
                }
                return nil
            }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        guard let source else { stop(); return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
    }
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
