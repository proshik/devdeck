import AppKit
import SwiftUI
import Observation

@MainActor protocol BrightnessOSDPresenting: AnyObject {
    func show(display: BrightnessDisplay, value: Double, nits: Double?)
    func hide()
}

@MainActor @Observable final class BrightnessOSDContent {
    var name: String
    var value: Double
    var nits: Double?
    init(name: String, value: Double, nits: Double? = nil) { self.name = name; self.value = value; self.nits = nits }
    var level: String { BrightnessLevelText.text(value: value, nits: nits) }
}

struct BrightnessOSDView: View {
    let content: BrightnessOSDContent
    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text(content.name).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(content.level)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit().fixedSize()
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: Capsule())
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min.fill").font(.system(size: 12)).frame(width: 16)
                VStack(spacing: 3) {
                    GeometryReader { geometry in
                        Capsule().fill(.primary.opacity(0.13))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.primary).frame(width: geometry.size.width * content.value)
                            }
                    }.frame(height: 4)
                    HStack(spacing: 0) {
                        ForEach(0..<17) { _ in
                            Circle().fill(.primary.opacity(0.25))
                                .frame(width: 1.5, height: 1.5).frame(maxWidth: .infinity)
                        }
                    }
                }
                Image(systemName: "sun.max.fill").font(.system(size: 15)).frame(width: 16)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(content.name + ", " + content.level)
    }
}

final class BrightnessOSDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns one reusable panel and its bounded hide task. All values passed here are readbacks.
@MainActor final class BrightnessOSDController: BrightnessOSDPresenting {
    private(set) var panel: BrightnessOSDPanel?
    private(set) var content: BrightnessOSDContent?
    private var hideTask: Task<Void, Never>?
    private var revision = 0
    private let screen: @MainActor (BrightnessDisplay) -> NSScreen?
    private let wait: (Duration) async throws -> Void

    init(screen: @escaping @MainActor (BrightnessDisplay) -> NSScreen? = BrightnessOSDController.screen,
         wait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.screen = screen; self.wait = wait
    }

    deinit {
        hideTask?.cancel()
        let remainingPanel = panel
        Task { @MainActor in remainingPanel?.close() }
    }

    private static func screen(for display: BrightnessDisplay) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  number.uint32Value == display.displayID,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return false }
            return CFUUIDCreateString(nil, uuid) as String == display.id
        }
    }

    static func frame(in visible: CGRect) -> CGRect {
        let width = min(320, max(0, visible.width - 32))
        let height = min(64, max(0, visible.height - 32))
        return CGRect(x: max(visible.minX, visible.maxX - width - 16),
                      y: max(visible.minY, visible.maxY - height - 16), width: width, height: height)
    }

    func show(display: BrightnessDisplay, value: Double, nits: Double?) {
        guard value.isFinite, (0...1).contains(value), let screen = screen(display) else { hide(); return }
        hideTask?.cancel(); revision += 1
        let epoch = revision
        let frame = Self.frame(in: screen.visibleFrame)
        guard frame.width > 0, frame.height > 0 else { hide(); return }
        let content = self.content ?? BrightnessOSDContent(name: display.name, value: value, nits: nits)
        content.name = display.name; content.value = value; content.nits = nits; self.content = content
        let panel: BrightnessOSDPanel
        if let existing = self.panel { panel = existing }
        else {
            panel = BrightnessOSDPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            // Remain readable above our zero-image and explicit software overlays.
            panel.level = .init(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: BrightnessOSDView(content: content))
            self.panel = panel
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().alphaValue = 1
        }
        hideTask = Task { [weak self, wait] in
            do {
                try await wait(.seconds(1))
                guard let self, !Task.isCancelled, self.revision == epoch else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.18
                    self.panel?.animator().alphaValue = 0
                }, completionHandler: nil)
                try await wait(.milliseconds(180))
                guard !Task.isCancelled, self.revision == epoch else { return }
                self.hide()
            } catch { /* hide/update owns cancellation and panel cleanup */ }
        }
    }

    func hide() {
        revision += 1; hideTask?.cancel(); hideTask = nil
        panel?.orderOut(nil); panel?.close(); panel = nil; content = nil
    }
}
