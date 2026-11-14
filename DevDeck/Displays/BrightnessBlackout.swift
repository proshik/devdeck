import AppKit

@MainActor protocol BrightnessBlackoutPresenting: AnyObject {
    func cover(_ display: BrightnessDisplay) throws -> Double
    func uncover(id: String) -> Double?
    func reconcile(_ displays: [BrightnessDisplay]) -> [BrightnessDisplay]
    func clear()
}

struct BrightnessBlackoutTarget {
    let id: String
    let displayID: CGDirectDisplayID
    let frame: CGRect
}

final class BrightnessBlackoutPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Zero is an owned black image, not backlight/power control. No hardware APIs are called.
@MainActor final class BrightnessBlackoutController: BrightnessBlackoutPresenting {
    private(set) var panels: [String: BrightnessBlackoutPanel] = [:]
    private var underlying: [String: BrightnessDisplay] = [:]
    private let target: @MainActor (BrightnessDisplay) -> BrightnessBlackoutTarget?
    private let cancelled: () -> Bool

    init(target: @escaping @MainActor (BrightnessDisplay) -> BrightnessBlackoutTarget? = BrightnessBlackoutController.target,
         cancelled: @escaping () -> Bool = { Task.isCancelled }) {
        self.target = target; self.cancelled = cancelled
    }

    deinit {
        let remaining = Array(panels.values)
        Task { @MainActor in for panel in remaining { panel.close() } }
    }

    private static func target(for display: BrightnessDisplay) -> BrightnessBlackoutTarget? {
        guard CGDisplayIsOnline(display.displayID) != 0,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
              }), let uuid = CGDisplayCreateUUIDFromDisplayID(display.displayID)?.takeRetainedValue() else { return nil }
        let id = CFUUIDCreateString(nil, uuid) as String
        guard id == display.id else { return nil }
        return BrightnessBlackoutTarget(id: id, displayID: display.displayID, frame: screen.frame)
    }

    private func matchedTarget(_ display: BrightnessDisplay) -> BrightnessBlackoutTarget? {
        guard let target = target(display), target.id == display.id, target.displayID == display.displayID,
              target.frame.width > 0, target.frame.height > 0 else { return nil }
        return target
    }

    func cover(_ display: BrightnessDisplay) throws -> Double {
        if cancelled() { throw CancellationError() }
        guard let value = display.value, value.isFinite, (0...1).contains(value),
              let target = matchedTarget(display) else {
            _ = uncover(id: display.id)
            throw BrightnessFailure.unavailable
        }
        if let old = underlying[display.id], old.displayID != display.displayID || old.method != display.method {
            _ = uncover(id: display.id)
        }
        let panel = panels[display.id] ?? BrightnessBlackoutPanel(contentRect: target.frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.backgroundColor = .black; panel.alphaValue = 1; panel.isOpaque = true; panel.hasShadow = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Same image layer as explicit software dimming; OSD is one level above it.
        panel.level = .init(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
        panel.setFrame(target.frame, display: true)
        panels[display.id] = panel
        if underlying[display.id] == nil { underlying[display.id] = display }
        panel.orderFrontRegardless()
        guard panel.isVisible else { _ = uncover(id: display.id); throw BrightnessFailure.write }
        if cancelled() {
            _ = uncover(id: display.id)
            throw CancellationError()
        }
        return 0
    }

    func uncover(id: String) -> Double? {
        panels.removeValue(forKey: id)?.close()
        return underlying.removeValue(forKey: id)?.value
    }

    func reconcile(_ displays: [BrightnessDisplay]) -> [BrightnessDisplay] {
        for id in Array(underlying.keys) {
            guard let old = underlying[id], let current = displays.first(where: { $0.id == id }),
                  old.displayID == current.displayID, old.method == current.method,
                  let value = current.value, value.isFinite, (0...1).contains(value),
                  let target = matchedTarget(current) else {
                _ = uncover(id: id); continue
            }
            underlying[id] = current
            panels[id]?.setFrame(target.frame, display: true)
        }
        return displays.map { display in
            var result = display
            if panels[display.id] != nil { result.value = 0 }
            return result
        }
    }

    func clear() {
        for id in Array(panels.keys) { _ = uncover(id: id) }
    }
}
