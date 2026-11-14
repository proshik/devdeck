import AppKit
import Observation

@MainActor @Observable final class DisplayBrightnessModel {
    private(set) var displays: [BrightnessDisplay] = []
    private(set) var errors: [String: String] = [:]
    private(set) var pending: [String: Double] = [:]
    private(set) var keyboardStatus = ""
    private(set) var refreshing = false
    @ObservationIgnored private let provider: any DisplayBrightnessProvider
    @ObservationIgnored private let osd: any BrightnessOSDPresenting
    @ObservationIgnored private let blackout: any BrightnessBlackoutPresenting
    @ObservationIgnored private var settings: () -> DisplayBrightnessSettings = { .init() }
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var keys: BrightnessKeys?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastMethods: [String: BrightnessMethod] = [:]
    @ObservationIgnored private var applying = false
    private struct KeyFeedback: Equatable {
        let sequence: Int
        let targetID: String
    }
    @ObservationIgnored private var feedbackSequence = 0
    @ObservationIgnored private var latestFeedback: KeyFeedback?
    @ObservationIgnored private var pendingFeedback: [String: KeyFeedback] = [:]
    private struct KeyObservation: Equatable {
        let displayID: UInt32
        let method: BrightnessMethod
        let actual: Double
    }
    private struct KeyIntent {
        let targetID: String
        let linked: Bool
        let requested: Double
        var observed: [String: KeyObservation]
    }
    @ObservationIgnored private var keyIntent: KeyIntent?

    init(provider: any DisplayBrightnessProvider = NativeBrightnessProvider(),
         osd: (any BrightnessOSDPresenting)? = nil,
         blackout: (any BrightnessBlackoutPresenting)? = nil) {
        self.provider = provider; self.osd = osd ?? BrightnessOSDController()
        self.blackout = blackout ?? BrightnessBlackoutController()
    }

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
        if epoch == generation && !suspended {
            let next = blackout.reconcile(result)
            let beforeKeys = keyObservations(targetID: "", linked: true, in: displays)
            let afterKeys = keyObservations(targetID: "", linked: true, in: next)
            let queuedKeyChanged = pendingFeedback.keys.contains { beforeKeys[$0] != afterKeys[$0] }
            if queuedKeyChanged || (keyIntent != nil && !matchesKeyIntent(in: next)) {
                // A key queued during discovery may use an obsolete baseline.
                // Drop it; absolute slider requests remain valid and stay queued.
                for id in Array(pendingFeedback.keys) { pending.removeValue(forKey: id) }
                pendingFeedback.removeAll()
                clearFeedback()
            }
            displays = next
            if let feedback = latestFeedback,
               !result.contains(where: { $0.id == feedback.targetID && $0.value != nil }) {
                clearFeedback()
            }
        }
        refreshing = false
        if epoch != generation && !suspended { await refresh() }
        startWriter()
    }

    /// A single worker coalesces slider motion and repeated key presses across all displays.
    func request(id: String, value: Double, fromKeys: Bool = false) {
        guard !suspended, value.isFinite, let target = displays.first(where: { $0.id == id }), target.value != nil else {
            if fromKeys { clearFeedback() }
            return
        }
        let linked = fromKeys ? settings().linkKeys : settings().linkSliders
        let feedback: KeyFeedback?
        if fromKeys {
            if latestFeedback?.targetID != id { osd.hide() }
            feedbackSequence += 1
            feedback = KeyFeedback(sequence: feedbackSequence, targetID: id)
            latestFeedback = feedback
            keyIntent = KeyIntent(targetID: id, linked: linked, requested: min(1, max(0, value)),
                                  observed: keyObservations(targetID: id, linked: linked, in: displays))
        } else {
            clearFeedback()
            feedback = nil
        }
        for display in displays where display.value != nil && (linked || display.id == id) {
            if value > 0 { uncover(id: display.id) }
            pending[display.id] = min(1, max(0, value))
            pendingFeedback[display.id] = feedback
        }
        startWriter()
    }

    private func startWriter() {
        guard writer == nil, !refreshing, !suspended, !pending.isEmpty else { return }
        writer = Task { [weak self] in
            while let self, let next = self.pending.first, !Task.isCancelled {
                // Keep the requested value observable until readback, including while in flight.
                let feedback = self.pendingFeedback[next.key]
                await self.apply(id: next.key, value: next.value, feedback: feedback)
                if self.pending[next.key] == next.value && self.pendingFeedback[next.key] == feedback {
                    self.pending.removeValue(forKey: next.key)
                    self.pendingFeedback.removeValue(forKey: next.key)
                }
            }
            self?.writer = nil
            self?.startWriter()
        }
    }

    func apply(id: String, value: Double) async {
        clearFeedback()
        await apply(id: id, value: value, feedback: nil)
    }

    private func apply(id: String, value: Double, feedback: KeyFeedback?) async {
        guard !Task.isCancelled, !refreshing, !suspended, value.isFinite,
              let display = displays.first(where: { $0.id == id }), display.value != nil else { return }
        let epoch = generation
        applying = true
        defer { applying = false }
        let requested = min(1, max(0, value))
        do {
            let actual: Double
            if requested == 0 {
                actual = try blackout.cover(display)
                try Task.checkCancellation()
            } else {
                uncover(id: id)
                actual = try await provider.set(display, value: requested)
            }
            guard epoch == generation, let index = displays.firstIndex(where: { $0.id == id }) else { return }
            guard actual.isFinite, (0...1).contains(actual) else { throw BrightnessFailure.readback }
            displays[index].value = actual
            observeOwnValue(id: id)
            errors.removeValue(forKey: id)
            if let feedback, feedback == latestFeedback, feedback.targetID == id, !Task.isCancelled {
                osd.show(display: displays[index], value: actual)
            }
        } catch BrightnessFailure.unconfirmed(let actual) {
            guard epoch == generation, let index = displays.firstIndex(where: { $0.id == id }) else { return }
            displays[index].value = actual
            discardKeyIntent(affectedBy: id)
            errors[id] = L10n.brightnessWriteFailed
            rejectFeedback(feedback)
        } catch {
            guard epoch == generation else { return }
            if requested == 0 { uncover(id: id) }
            discardKeyIntent(affectedBy: id)
            errors[id] = L10n.brightnessWriteFailed
            rejectFeedback(feedback)
        }
    }

    private func invalidate() {
        generation += 1
        blackout.clear()
        clearFeedback(); pendingFeedback.removeAll()
        writer?.cancel()
        pending.removeAll()
        displays = []
    }
    private func uncover(id: String) {
        if let actual = blackout.uncover(id: id), let index = displays.firstIndex(where: { $0.id == id }) {
            displays[index].value = actual
            observeOwnValue(id: id)
        }
    }
    private func keyObservations(targetID: String, linked: Bool, in displays: [BrightnessDisplay]) -> [String: KeyObservation] {
        var result: [String: KeyObservation] = [:]
        for display in displays where linked || display.id == targetID {
            if let actual = display.value, actual.isFinite {
                result[display.id] = KeyObservation(displayID: display.displayID, method: display.method, actual: actual)
            }
        }
        return result
    }
    private func matchesKeyIntent(in displays: [BrightnessDisplay], targetID: String? = nil) -> Bool {
        guard let intent = keyIntent, intent.targetID == (targetID ?? intent.targetID),
              intent.linked == settings().linkKeys, intent.observed[intent.targetID] != nil else { return false }
        return intent.observed == keyObservations(targetID: intent.targetID, linked: intent.linked, in: displays)
    }
    private func observeOwnValue(id: String) {
        guard var intent = keyIntent, intent.observed[id] != nil,
              let display = displays.first(where: { $0.id == id }), let actual = display.value else { return }
        // Our quantized readback updates the observation, never the accumulated request.
        intent.observed[id] = KeyObservation(displayID: display.displayID, method: display.method, actual: actual)
        keyIntent = intent
    }
    private func discardKeyIntent(affectedBy id: String) {
        if keyIntent?.observed[id] != nil { keyIntent = nil }
    }
    private func clearFeedback() {
        keyIntent = nil
        latestFeedback = nil
        osd.hide()
    }
    private func rejectFeedback(_ feedback: KeyFeedback?) {
        if let feedback, feedback == latestFeedback { clearFeedback() }
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
              let actual = target.value else {
            clearFeedback(); keyboardStatus = L10n.brightnessUnsupported; return
        }
        keyboardStatus = ""
        let step = (fine ? 1.0 / 64 : 1.0 / 16) * (increase ? 1 : -1)
        let base: Double
        if matchesKeyIntent(in: displays, targetID: target.id), let intent = keyIntent {
            base = intent.requested
        } else {
            keyIntent = nil
            // A slider in flight is a new baseline; old key sessions are not.
            base = pendingFeedback[target.id] == nil ? (pending[target.id] ?? actual) : actual
        }
        request(id: target.id, value: base + step, fromKeys: true)
    }

    func updateKeyboard() {
        guard settings().keyboardEnabled, !suspended else {
            if keys != nil { clearFeedback() }
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
