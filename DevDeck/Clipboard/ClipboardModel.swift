import Foundation
import Observation

@MainActor @Observable final class ClipboardModel {
    private(set) var entries: [ClipboardEntry] = []
    private(set) var settings = ClipboardSettings()
    private(set) var access: ClipboardAccess = .allowed
    private(set) var error: ClipboardHistoryError?
    private(set) var copyFailed = false
    private(set) var copiedID: UUID?
    private(set) var isBusy = false
    @ObservationIgnored private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var pasteFailure: ClipboardPasteFailure?
    private(set) var pastePermission = false
    private(set) var missingFile: String?
    @ObservationIgnored private let paster: ClipboardPasteController?
    @ObservationIgnored private let files: any ClipboardFileChecking
    @ObservationIgnored var dismissPanel: () -> Void = {}
    var isPasting: Bool { paster?.isBusy ?? false }
    private let history: ClipboardHistory
    private let pasteboard: any ClipboardPasteboard
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var count: Int
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var appliedSettings: ClipboardSettings?
    @ObservationIgnored private var lastPrune = Date.distantPast
    @ObservationIgnored private var settingsProvider: () -> ClipboardSettings = { .init() }
    init(history: ClipboardHistory = ClipboardHistory(storage: ClipboardFileStorage()),
         pasteboard: (any ClipboardPasteboard)? = nil,
         paster: ClipboardPasteController? = nil, files: any ClipboardFileChecking = ClipboardFileAvailability()) {
        let board = pasteboard ?? SystemClipboardPasteboard()
        self.history = history; self.pasteboard = board; count = board.changeCount
        self.paster = paster; self.files = files
    }
    func start(settings: @escaping () -> ClipboardSettings) {
        stop(); settingsProvider = settings; paster?.platform.start()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    await self.synchronize(self.settingsProvider())
                    await self.poll()
                } else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    func stop() { timer?.cancel(); timer = nil; paster?.platform.stop() }
    func synchronize(_ newSettings: ClipboardSettings, now: Date = Date()) async {
        if settings != newSettings {
            settings = newSettings; count = pasteboard.changeCount; generation += 1
        }
        updateAccess(); pastePermission = paster?.platform.trusted ?? false
        guard !isBusy, appliedSettings != newSettings || now.timeIntervalSince(lastPrune) >= 60 else { return }
        isBusy = true; defer { finishOperation() }
        do {
            await publish(try await history.load(settings: newSettings, now: now))
            appliedSettings = newSettings; lastPrune = now; error = nil
        } catch {
            await publish(await history.currentEntries())
            report(error)
        }
    }
    func poll(now: Date = Date()) async {
        updateAccess()
        guard !isBusy, settings.enabled, !settings.paused, access == .allowed,
              appliedSettings == settings else { return }
        let observed = pasteboard.changeCount
        guard observed != count else { return }
        let excluded = Set(settings.excludedBundleIDs)
        guard let snapshot = pasteboard.snapshot(excludedBundleIDs: excluded),
              pasteboard.changeCount == observed else {
            // A concurrent copy while reading must be retried on the next poll.
            if pasteboard.changeCount == observed { count = observed }
            return
        }
        guard snapshot.isEligible,
              snapshot.sourceBundleID.map({ !excluded.contains($0) }) ?? true,
              snapshot.activeBundleID.map({ !excluded.contains($0) }) ?? true else { count = observed; return }
        isBusy = true; defer { finishOperation() }
        let token = generation
        let content: ClipboardContent?
        if !snapshot.fileURLs.isEmpty { content = .files(snapshot.fileURLs) }
        else if let type = snapshot.imageType {
            let data = snapshot.imageData ?? Data()
            content = await Task.detached { ClipboardImageProcessor.inspect(data, type: type).map(ClipboardContent.image) }.value
            guard token == generation else { return }
            guard content != nil else { count = observed; error = .entryTooLarge; return }
        } else { content = snapshot.text.map(ClipboardContent.text) }
        guard let content else { count = observed; return }
        if content.kind != .image, !content.isValid { count = observed; error = .entryTooLarge; return }
        do {
            await publish(try await history.capture(ClipboardEntry(content: content, capturedAt: now,
                        sourceBundleID: snapshot.sourceBundleID, sourceName: snapshot.sourceName), settings: settings, now: now))
            if token == generation { count = observed }
            error = nil
        } catch { report(error) } // count stays pending, so transient write failures can be retried
    }
    @discardableResult func copy(_ entry: ClipboardEntry) -> Bool {
        guard !isPasting else { return false }
        pasteFailure = nil
        return copyEntry(entry) != nil
    }
    private func copyEntry(_ entry: ClipboardEntry) -> Int? {
        missingFile = nil
        if case .files(let urls) = entry.content, let missing = urls.first(where: { !files.isAvailable($0) }) {
            missingFile = missing.lastPathComponent; copyFailed = true; return nil
        }
        guard let writtenCount = pasteboard.write(entry) else { copyFailed = true; return nil }
        count = writtenCount; generation += 1; copyFailed = false; copiedID = entry.id
        return writtenCount
    }
    func capturePasteTarget() { paster?.platform.captureTarget() }
    func requestPastePermission() {
        paster?.platform.requestPermission(); pastePermission = paster?.platform.trusted ?? false
    }
    func paste(_ entry: ClipboardEntry) async {
        guard !isPasting else { return }
        pasteFailure = nil
        guard let paster else { pasteFailure = .target; return }
        let result = await paster.perform(enabled: settings.pasteEnabled, changeCount: { self.pasteboard.changeCount },
            copy: { self.copyEntry(entry) }, dismiss: { self.dismissPanel() })
        pasteFailure = result
        pastePermission = paster.platform.trusted
    }
    func fileStates(_ urls: [URL]) async -> [URL: Bool] {
        let checker = files
        return await Task.detached { Dictionary(urls.map { ($0, checker.isAvailable($0)) }, uniquingKeysWith: { first, _ in first }) }.value
    }
    func requestAccess() {
        pasteboard.requestAccess(); updateAccess(); count = pasteboard.changeCount
    }
    func setPinned(_ entry: ClipboardEntry) async {
        await acquireOperation()
        defer { finishOperation() }
        do { await publish(try await history.setPinned(entry.id, pinned: !entry.isPinned, settings: settings)); error = nil }
        catch { report(error) }
    }
    func remove(_ entry: ClipboardEntry) async {
        await acquireOperation()
        defer { finishOperation() }
        do { await publish(try await history.remove(entry.id)); error = nil }
        catch { report(error) }
    }
    func clear(includingPinned: Bool) async {
        await acquireOperation()
        defer { finishOperation() }
        do {
            await publish(try await history.clear(includingPinned: includingPinned))
            error = nil; count = pasteboard.changeCount; generation += 1
            appliedSettings = nil
        } catch { report(error) }
    }
    private func publish(_ value: [ClipboardEntry]) async {
        entries = value
        await ClipboardPreviewCache.shared.retainOnly(Set(value.map(\.id)))
    }
    /// Explicit user mutations queue; background polling may skip a busy cycle.
    private func acquireOperation() async {
        if isBusy { await withCheckedContinuation { operationWaiters.append($0) } }
        else { isBusy = true }
    }
    private func finishOperation() {
        if operationWaiters.isEmpty { isBusy = false }
        else { operationWaiters.removeFirst().resume() } // retain ownership during handoff
    }
    func retry() async { appliedSettings = nil; await synchronize(settingsProvider()) }
    func search(_ query: String, pinnedOnly: Bool = false, kind: ClipboardContent.Kind? = nil) -> [ClipboardEntry] {
        entries.filter { (!pinnedOnly || $0.isPinned) && (kind == nil || $0.kind == kind) && (query.isEmpty || $0.searchText.localizedCaseInsensitiveContains(query)
            || ($0.sourceName?.localizedCaseInsensitiveContains(query) ?? false)
            || ($0.sourceBundleID?.localizedCaseInsensitiveContains(query) ?? false)) }
            .sorted { a, b in
                if a.isPinned != b.isPinned { return a.isPinned }
                return a.capturedAt > b.capturedAt
            }
    }
    var errorMessage: String? {
        switch error {
        case .damaged: L10n.clipboardDamaged
        case .writeFailed: L10n.clipboardWriteFailed
        case .pinnedLimit: L10n.clipboardPinLimit
        case .entryTooLarge: L10n.clipboardTooLarge
        case nil:
            if let missingFile { L10n.clipboardMissingFile + ": " + missingFile }
            else if let pasteFailure {
                switch pasteFailure {
                case .permission: L10n.clipboardPastePermission
                case .target: L10n.clipboardPasteTargetFailed
                case .changed: L10n.clipboardPasteChanged
                case .copy: L10n.clipboardCopyFailed
                case .disabled: L10n.clipboardPasteOff
                case .busy, .cancelled: L10n.clipboardPasteCancelled
                }
            } else { copyFailed ? L10n.clipboardCopyFailed : nil }
        }
    }
    private func updateAccess() {
        let current = pasteboard.access
        if current != access { access = current; count = pasteboard.changeCount; generation += 1 }
    }
    private func report(_ error: Error) { self.error = error as? ClipboardHistoryError ?? .writeFailed }
}
