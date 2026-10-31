import AppKit
import Observation

@MainActor @Observable final class DisplayBrightnessModel {
    private(set) var displays: [BrightnessDisplay] = []
    private(set) var errors: [String: String] = [:]
    private(set) var pending: [String: Double] = [:]
    private(set) var keyboardStatus = ""
    private(set) var refreshing = false
    @ObservationIgnored private let provider: any DisplayBrightnessProvider
    @ObservationIgnored private var settings: () -> DisplayBrightnessSettings = { .init() }
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var keys: BrightnessKeys?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastMethods: [String: BrightnessMethod] = [:]
    @ObservationIgnored private var applying = false

    init(provider: any DisplayBrightnessProvider = NativeBrightnessProvider()) { self.provider = provider }

    func start(settings: @escaping () -> DisplayBrightnessSettings) {
        self.settings = settings
        guard timer == nil else { return }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = false; await self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.invalidate(); await self?.refresh() }
        })
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                self?.updateKeyboard()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() async {
        let current = settings().methods
        if current != lastMethods { invalidate(); lastMethods = current }
        guard !refreshing, !applying, pending.isEmpty, !suspended else { return }
        refreshing = true
        let epoch = generation
        let result = await provider.discover(methods: current)
        if epoch == generation && !suspended { displays = result }
        refreshing = false
        if epoch != generation && !suspended { await refresh() }
        startWriter()
    }

    /// A single worker coalesces slider motion and repeated key presses across all displays.
    func request(id: String, value: Double, fromKeys: Bool = false) {
        guard !suspended, value.isFinite, let target = displays.first(where: { $0.id == id }), target.value != nil else { return }
        let linked = fromKeys ? settings().linkKeys : settings().linkSliders
        for display in displays where display.value != nil && (linked || display.id == id) {
            pending[display.id] = min(1, max(0, value))
        }
        startWriter()
    }

    private func startWriter() {
        guard writer == nil, !refreshing, !suspended, !pending.isEmpty else { return }
        writer = Task { [weak self] in
            while let self, let next = self.pending.first, !Task.isCancelled {
                // Keep the requested value observable until readback, including while in flight.
                await self.apply(id: next.key, value: next.value)
                if self.pending[next.key] == next.value { self.pending.removeValue(forKey: next.key) }
            }
            self?.writer = nil
            self?.startWriter()
        }
    }

    func apply(id: String, value: Double) async {
        guard !Task.isCancelled, !refreshing, !suspended, value.isFinite,
              let display = displays.first(where: { $0.id == id }), display.value != nil else { return }
        let epoch = generation
        applying = true
        defer { applying = false }
        do {
            let actual = try await provider.set(display, value: min(1, max(0, value)))
            guard epoch == generation, let index = displays.firstIndex(where: { $0.id == id }) else { return }
            displays[index].value = actual
            errors.removeValue(forKey: id)
        } catch {
            guard epoch == generation else { return }
            errors[id] = L10n.brightnessWriteFailed
        }
    }

    private func invalidate() {
        generation += 1
        writer?.cancel()
        pending.removeAll()
        displays = []
    }
    private func suspend() {
        suspended = true; invalidate(); keys?.stop(); keys = nil
        Task { await provider.reset() }
    }
    func stop() {
        suspend(); timer?.cancel(); timer = nil; writer?.cancel(); writer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    func handleKey(increase: Bool, fine: Bool, at point: CGPoint) {
        // CGEvent.location and CGDisplayBounds share the upper-left coordinate space.
        guard let target = BrightnessRouting.target(at: point, displays: displays),
              let actual = target.value else { keyboardStatus = L10n.brightnessUnsupported; return }
        keyboardStatus = ""
        let step = (fine ? 1.0 / 64 : 1.0 / 16) * (increase ? 1 : -1)
        request(id: target.id, value: (pending[target.id] ?? actual) + step, fromKeys: true)
    }

    func updateKeyboard() {
        guard settings().keyboardEnabled, !suspended else {
            keys?.stop(); keys = nil; keyboardStatus = ""; return
        }
        guard keys == nil else { return }
        let handler = BrightnessKeys { [weak self] increase, fine in
            guard let self else { return }
            if let point = CGEvent(source: nil)?.location { self.handleKey(increase: increase, fine: fine, at: point) }
        }
        if handler.start() { keys = handler; keyboardStatus = "" }
        else { keyboardStatus = L10n.brightnessPermission }
    }
}
