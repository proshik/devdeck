import AppKit
import ApplicationServices
import Observation

struct ClipboardPasteTarget: Equatable, Sendable {
    let identity: UUID
    let pid: Int32
    let name: String
}
enum ClipboardPasteFailure: Equatable { case disabled, permission, target, copy, changed, busy, cancelled }

@MainActor protocol ClipboardPasting: AnyObject {
    var trusted: Bool { get }
    var target: ClipboardPasteTarget? { get }
    func start()
    func stop()
    func captureTarget()
    func requestPermission()
    func isAvailable(_ target: ClipboardPasteTarget) -> Bool
    func activate(_ target: ClipboardPasteTarget) -> Bool
    func isFrontmost(_ target: ClipboardPasteTarget) -> Bool
    func sendPaste(to target: ClipboardPasteTarget) -> Bool
}

@MainActor @Observable final class ClipboardPasteController {
    private(set) var isBusy = false
    @ObservationIgnored let platform: any ClipboardPasting
    @ObservationIgnored private let pause: () async -> Void
    init(platform: any ClipboardPasting, pause: @escaping () async -> Void = { try? await Task.sleep(for: .milliseconds(50)) }) {
        self.platform = platform; self.pause = pause
    }
    convenience init() { self.init(platform: SystemClipboardPasting()) }
    func perform(enabled: Bool, changeCount: () -> Int, copy: () -> Int?, dismiss: () -> Void) async -> ClipboardPasteFailure? {
        guard !isBusy else { return .busy }
        guard !Task.isCancelled else { return .cancelled }
        guard enabled else { return .disabled }
        guard platform.trusted else { return .permission }
        guard let target = platform.target, target.pid != ProcessInfo.processInfo.processIdentifier,
              platform.isAvailable(target) else { return .target }
        isBusy = true; defer { isBusy = false }
        guard let writtenCount = copy() else { return .copy }
        dismiss()
        guard platform.activate(target) else { return .target }
        for _ in 0..<20 {
            guard !Task.isCancelled else { return .cancelled }
            guard platform.isAvailable(target) else { return .target }
            if platform.isFrontmost(target) { break }
            await pause()
        }
        guard !Task.isCancelled else { return .cancelled }
        guard platform.trusted else { return .permission }
        guard platform.isAvailable(target), platform.isFrontmost(target) else { return .target }
        guard changeCount() == writtenCount else { return .changed }
        return platform.sendPaste(to: target) ? nil : .target
    }
}

/// Keeps a running-application instance and a fresh token, so a recycled PID cannot
/// become the destination of an earlier request. No observer/permission prompt in init.
@MainActor final class SystemClipboardPasting: ClipboardPasting {
    private var application: NSRunningApplication?
    private(set) var target: ClipboardPasteTarget?
    private var observer: NSObjectProtocol?
    var trusted: Bool { AXIsProcessTrusted() }
    func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func start() {
        guard observer == nil else { return }
        captureTarget()
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.remember(app) }
            }
    }
    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil; application = nil; target = nil
    }
    func captureTarget() { if let app = NSWorkspace.shared.frontmostApplication { remember(app) } }
    private func remember(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.activationPolicy == .regular,
              !app.isTerminated, app.bundleIdentifier != "capital.frontier.DevDeck",
              app.bundleIdentifier != "local.devdeck.development" else { return }
        if application?.processIdentifier == app.processIdentifier && application?.launchDate == app.launchDate { return }
        application = app
        target = .init(identity: UUID(), pid: app.processIdentifier, name: app.localizedName ?? "")
    }
    func isAvailable(_ target: ClipboardPasteTarget) -> Bool {
        guard self.target == target, let app = application, !app.isTerminated,
              app.processIdentifier == target.pid, target.pid != ProcessInfo.processInfo.processIdentifier,
              let current = NSRunningApplication(processIdentifier: target.pid) else { return false }
        return !current.isTerminated && current.launchDate == app.launchDate && current.bundleIdentifier == app.bundleIdentifier
    }
    func activate(_ target: ClipboardPasteTarget) -> Bool {
        guard isAvailable(target), let application else { return false }
        return application.activate(from: .current, options: [])
    }
    func isFrontmost(_ target: ClipboardPasteTarget) -> Bool {
        isAvailable(target) && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
    }
    func sendPaste(to target: ClipboardPasteTarget) -> Bool {
        guard trusted, isFrontmost(target),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(target.pid); up.postToPid(target.pid)
        return true
    }
}
