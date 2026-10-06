import AppKit

/// A menu bar launch stays accessory; an open full window participates in Dock and Cmd-Tab.
@MainActor
final class MainWindowActivationController {
    private let application: NSApplication
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var isClosing = false

    init(application: NSApplication? = nil) {
        self.application = application ?? .shared
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func prepareToOpen() {
        isClosing = false
        setPolicy(.regular)
    }

    func track(_ window: NSWindow) {
        guard self.window !== window else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        self.window = window
        prepareToOpen()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isClosing = true
                    self?.setPolicy(.accessory)
                }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isClosing else { return }
                    self.setPolicy(.regular)
                }
            }
        ]
    }

    private func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard application.activationPolicy() != policy else { return }
        application.setActivationPolicy(policy)
    }
}
