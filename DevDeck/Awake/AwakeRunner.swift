import Foundation

protocol AwakeLease: Sendable {
    var url: URL { get }
    func create() -> Bool
    func remove() -> Bool
    func isReady(owner: UUID) -> Bool
}

struct LiveAwakeLease: AwakeLease {
    let url: URL
    func create() -> Bool { LivePrivateFile(url: url).write("lease") }
    func remove() -> Bool { LivePrivateFile(url: url).remove() }
    func isReady(owner: UUID) -> Bool {
        (try? String(contentsOf: AwakeHelper.readyURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == owner.uuidString
    }
}

/// A synthetic daemon's adapter. Authorization does not count as "running": only the
/// privileged helper's receipt, written after pmset succeeds, emits the daemon's started event.
struct AwakeCommandRunner: CommandRunner {
    func start(_ command: Command) -> any RunningProcess {
        let owner = UUID()
        let lease = LiveAwakeLease(url: PrivateFile.applicationSupportDirectory
            .appendingPathComponent("awake-leases/\(owner.uuidString)"))
        let recovery = command.env["DEVDECK_AWAKE_RECOVERY"] == "1"
        let seconds = Int(command.env["DEVDECK_AWAKE_SECONDS"] ?? "") ?? 7200
        let privileged = Command(name: command.name,
                                 command: AwakeHelper.script(lease: lease.url, owner: owner,
                                     parentPID: ProcessInfo.processInfo.processIdentifier,
                                     seconds: seconds, recoveryOnly: recovery), needsSudo: true)
        return AwakeProcess(lease: lease, owner: owner, recovery: recovery) {
            // Use the native password dialog consistently; never kill the root helper to stop it.
            let script = "with timeout of 7500 seconds\ndo shell script \"\(AppleScriptEscaper.escape(privileged.command))\" with administrator privileges\nend timeout"
            return StreamingProcess(makeProcess: {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                process.standardInput = FileHandle.nullDevice
                return process
            }, startedPID: { _ in nil },
               mapTerminal: { code, cancelled in cancelled ? .cancelled : .terminated(exitCode: code) },
               cancelMarkers: ["User canceled", "(-128)"])
        }
    }
}

/// Mutable stream state is protected by lock. The helper restores sleep before its terminal
/// event; stop removes only a lease. Even SIGKILL of DevDeck is noticed by the root watchdog.
final class AwakeProcess: RunningProcess, @unchecked Sendable {
    let token = UUID()
    let output: AsyncStream<RunnerOutput>
    private let continuation: AsyncStream<RunnerOutput>.Continuation
    private let lease: any AwakeLease
    private let owner: UUID
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var stopped = false
    private var pending: [RunnerOutput] = []
    private var consumer: Task<Void, Never>?
    private var poller: Task<Void, Never>?

    init(lease: any AwakeLease, owner: UUID, recovery: Bool = false,
         launch: () -> any RunningProcess) {
        self.lease = lease
        self.owner = owner
        (output, continuation) = AsyncStream.makeStream(of: RunnerOutput.self)
        guard recovery || lease.create() else {
            receive(.line("Cannot create keep-awake lease.", stream: .stderr))
            receive(.terminated(exitCode: 1))
            return
        }
        let helper = launch()
        consumer = Task { [weak self] in
            for await event in helper.output { self?.receive(event) }
        }
        if !recovery {
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.pollReady() else { return }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }

    deinit { consumer?.cancel(); poller?.cancel() }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        if !lease.remove() {
            continuation.yield(.line("Could not revoke keep-awake lease; the helper's timer remains active.", stream: .stderr))
        }
    }

    @discardableResult
    func pollReady() -> Bool {
        let ready = lease.isReady(owner: owner)
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        if ready && !stopped { startLocked() }
        return !started
    }

    private func startLocked() {
        guard !started else { return }
        started = true
        continuation.yield(.started(pid: nil))  // root helper must never be adopted/killed by PID
        pending.forEach { continuation.yield($0) }
        pending.removeAll()
    }

    private func receive(_ event: RunnerOutput) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        switch event {
        case .started: break   // osascript's start is authorization, not helper readiness
        case .line:
            if started { continuation.yield(event) } else { pending.append(event) }
        case .terminated, .cancelled:
            pending.forEach { continuation.yield($0) }
            pending.removeAll()
            finished = true
            _ = lease.remove()
            continuation.yield(event)
            continuation.finish()
            // The poller observes finished on its next tick; no task-handle race during init.
        }
    }
}
