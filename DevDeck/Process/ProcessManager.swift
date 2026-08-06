import Foundation
import Observation

/// Timing policy for the daemon watchdog and the port-conflict resolver.
/// Injectable so tests run with millisecond values instead of wall-clock seconds.
struct SupervisionPolicy: Sendable {
    /// Pauses before consecutive restart attempts; the count is the attempt limit.
    var restartDelays: [Duration] = [.seconds(2), .seconds(3), .seconds(5)]
    /// `daemonRunning` held this long → the failure counter resets.
    var stabilityWindow: Duration = .seconds(10)
    /// `isAlive` poll period for adopted daemons (they have no output stream).
    var adoptedPollInterval: Duration = .seconds(3)
    /// Port-free poll period after killing the occupant.
    var portFreePollInterval: Duration = .milliseconds(200)
    /// How long to wait for the port to free after SIGTERM (and once more after SIGKILL).
    var portFreeTimeout: Duration = .seconds(3)
}

/// State machine for running commands and chains. `@MainActor @Observable`:
/// the popover and the main window read consistent state (like `CommandStore`).
/// The runner is injected (prod → the real router; tests → `FakeCommandRunner`).
///
/// All NON-Sendable process machinery is locked inside the runner; only Sendable
/// `RunnerOutput` values cross the actor boundary. `apply` is the single state
/// mutator, always on main.
///
/// Run state is keyed by `RunningProcess.token` (fresh on every start), so late
/// events from a preempted run and concurrent runs of the same command (e.g. in two
/// chains) don't collide.
@MainActor
@Observable
final class ProcessManager {
    enum RunState: Equatable {
        case idle
        case running
        case daemonRunning
        case succeeded
        case failed(code: Int32)
    }

    enum ChainState: Equatable {
        case idle
        case running(currentIndex: Int)
        case succeeded
        case failed(atIndex: Int, code: Int32)
        case stopped
    }

    /// Code for a chain command missing from the map.
    static let missingCommandCode: Int32 = -2

    /// Code for a `routeThroughProxy` command that couldn't resolve a proxy.
    static let proxyUnavailableCode: Int32 = -3

    /// Watchdog phase of a daemon (drives the shield button in the popover).
    enum WatchdogPhase: Equatable {
        case armed                      // watching a live daemon
        case restarting(attempt: Int)   // waiting out the pause before restart N
        case pausedOnConflict           // port occupied — waiting for the user's decision
        case gaveUp                     // restart limit exhausted
    }

    /// Outcome of a single chain step.
    private enum StepOutcome {
        case succeeded
        case daemonRunning   // daemon step: success for advancing, the daemon is left running
        case failed(code: Int32)
        case cancelled       // user cancelled a sudo step → stop the chain
    }

    private(set) var states: [UUID: RunState] = [:]          // by Command.id (popover rows)
    private(set) var chainStates: [UUID: ChainState] = [:]   // by Chain.id
    private(set) var logs: [UUID: RingBuffer<LogLine>] = [:] // by Command.id
    /// Watchdog phase per daemon; no key — watchdog inactive.
    private(set) var watchdogPhases: [UUID: WatchdogPhase] = [:]
    /// Detected port conflicts (the inline panel in the popover); no key — no conflict.
    private(set) var portConflicts: [UUID: PortConflict] = [:]

    /// "Port N is occupied by X (PID Y)" — everything the popover panel and
    /// "Kill & start" need. `command` is a snapshot to launch after resolution.
    struct PortConflict: Equatable {
        let port: Int
        let occupant: PortOccupant
        let command: Command
        var resolving: Bool = false
    }

    @ObservationIgnored private let runner: any CommandRunner
    @ObservationIgnored private let maxLogLines: Int
    @ObservationIgnored private var active: [UUID: any RunningProcess] = [:]      // by Command.id
    @ObservationIgnored private var consumers: [UUID: Task<Void, Never>] = [:]    // by Command.id
    @ObservationIgnored private var chainTasks: [UUID: Task<Void, Never>] = [:]   // by Chain.id
    /// Token of the current chain run — a preempted driver doesn't write to chainStates.
    @ObservationIgnored private var chainTokens: [UUID: UUID] = [:]
    /// The command running right now in a given chain (for stopChain).
    @ObservationIgnored private var chainCurrentCommand: [UUID: UUID] = [:]
    /// Continuations for a chain awaiting a step, keyed by the run's RunningProcess.token.
    @ObservationIgnored private var stepWaiters: [UUID: CheckedContinuation<StepOutcome, Never>] = [:]
    /// Commands stopped BY THE USER — their terminal event is shown neutrally (idle), not red.
    @ObservationIgnored private var stopRequested: Set<UUID> = []
    @ObservationIgnored private let appController: any AppController
    @ObservationIgnored private let appQuitTimeout: TimeInterval
    @ObservationIgnored private let notifier: any Notifier
    @ObservationIgnored private let reaper: any DaemonReaper
    /// Token of the current memory orchestration for a command — a preempted run doesn't relaunch.
    @ObservationIgnored private var memoryTokens: [UUID: UUID] = [:]
    /// Adopted daemons: id → pid. They have no managed Process — stop hits the PID.
    @ObservationIgnored private var adoptedPIDs: [UUID: Int32] = [:]

    // MARK: watchdog state
    @ObservationIgnored private let portInspector: any PortInspector
    @ObservationIgnored private let policy: SupervisionPolicy
    /// Daemons the watchdog currently watches (armed). Distinct from `Command.watchdogEnabled`:
    /// a user stop deactivates watching without touching the persisted flag.
    @ObservationIgnored private var watchdogArmed: Set<UUID> = []
    /// Consecutive failed-restart counter; reset by a stable run or a fresh user start.
    @ObservationIgnored private var watchdogFailures: [UUID: Int] = [:]
    @ObservationIgnored private var watchdogRestartTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var stabilityTasks: [UUID: Task<Void, Never>] = [:]
    /// Snapshot of the last started daemon command — restarts and the reactive
    /// port check need the full model, not just the id.
    @ObservationIgnored private var lastStarted: [UUID: Command] = [:]
    @ObservationIgnored private var adoptedPollTask: Task<Void, Never>?
    /// Token of the current proactive port pre-check — a rapid re-run preempts the older check.
    @ObservationIgnored private var portPrecheckTokens: [UUID: UUID] = [:]

    // MARK: VM sampler
    @ObservationIgnored private let vmProbe: any VMMemoryProbing
    @ObservationIgnored var isVMMonitoringEnabled: () -> Bool
    @ObservationIgnored private var vmPeak: [UUID: VMMemoryInfo] = [:]
    @ObservationIgnored private var vmSamplerTask: Task<Void, Never>?
    /// The last VM snapshot taken (updated asynchronously, read without locking).
    private(set) var cachedVMSample: VMMemoryInfo?

    // MARK: minikube sampler (Tier 2)
    @ObservationIgnored private let minikubeProbe: any MinikubeProbing
    @ObservationIgnored private let oomInspector: any OOMInspecting
    /// Defaults to false: without explicitly wiring the flag, the ssh probe into the VM is never called (including in tests).
    @ObservationIgnored var isMinikubeMonitoringEnabled: () -> Bool
    @ObservationIgnored private var minikubeStats: [UUID: MinikubeRunStats] = [:]
    /// The last minikube snapshot; present only during a run (nil between runs).
    private(set) var cachedMinikubeSample: MinikubeSample?
    /// Live colima cpus + memory limit for the `-j` advisory; nil until resolved (then defaults apply).
    private(set) var vmBuildConfig: VMBuildConfig?
    /// Memory layers ("colima"/"minikube") already warned about this sampler session — debounce
    /// to one notification per layer per run; cleared when the sampler stops.
    @ObservationIgnored private var warnedThresholds: Set<String> = []
    /// Fraction of a VM/node memory limit at which a proactive high-memory warning fires.
    @ObservationIgnored private let memoryWarnThreshold = 0.90

    // MARK: host sampler (Tier 1)
    @ObservationIgnored private let hostProbe: any HostMetricsProbing
    @ObservationIgnored var isHostMonitoringEnabled: () -> Bool
    @ObservationIgnored private var hostPeak: [UUID: UInt64] = [:]       // build footprint peak per run
    @ObservationIgnored private var hostStats: [UUID: HostMetricsSample] = [:]  // last sample (pressure/compressor)
    @ObservationIgnored private var buildPIDs: [UUID: Int32] = [:]       // PID captured from .started
    /// Last host snapshot for the popover (live), updated by the sampler.
    private(set) var cachedHostSample: HostMetricsSample?
    /// Previous host sample + its timestamp, kept to compute the swap-out rate between ticks.
    @ObservationIgnored private var prevHostForRate: (sample: HostMetricsSample, time: Date)?
    /// Live swap-out/in rate (pages/sec) for the popover; nil until two samples are seen, cleared between runs.
    private(set) var cachedSwapOutRatePages: Double?
    private(set) var cachedSwapInRatePages: Double?

    // MARK: cluster health (colima + minikube)
    @ObservationIgnored private let clusterProbe: any ClusterHealthProbing
    @ObservationIgnored var isClusterHealthEnabled: () -> Bool

    // MARK: proxy routing
    /// Resolves whether a command must be launched through the LAN proxy. Injected by `AppDelegate`
    /// (a closure, not a type dependency — `ProcessManager` stays unaware of `ProxyManager`).
    @ObservationIgnored var proxyRouting: (Command) -> ProxyRouting = { _ in .notRouted }
    /// Every output line of every run, as it arrives. Injected by `AppDelegate` (a closure, not a
    /// type dependency — `ProcessManager` stays unaware of `ProxyManager`), which points it at the
    /// connected-clients monitor. The filtering for the proxy listener happens on the other side:
    /// the hook is generic, and one closure call per log line costs nothing.
    @ObservationIgnored var outputObserver: (UUID, String, OutputChannel) -> Void = { _, _, _ in }
    /// Last cluster-health snapshot for the popover; refreshed while the popover is open.
    private(set) var cachedClusterHealth: ClusterHealth?

    init(
        runner: any CommandRunner,
        notifier: any Notifier = NoopNotifier(),
        appController: any AppController = LiveAppController(),
        reaper: any DaemonReaper = LiveDaemonReaper(),
        portInspector: any PortInspector = LivePortInspector(),
        policy: SupervisionPolicy = SupervisionPolicy(),
        maxLogLines: Int = 2000,
        appQuitTimeout: TimeInterval = 10,
        vmProbe: any VMMemoryProbing = LiveVMMemoryProbe(),
        vmMonitoringEnabled: @escaping () -> Bool = { true },
        minikubeProbe: any MinikubeProbing = LiveMinikubeProbe(),
        oomInspector: any OOMInspecting = LiveOOMInspector(),
        minikubeMonitoringEnabled: @escaping () -> Bool = { false },
        hostProbe: any HostMetricsProbing = LiveHostMetricsProbe(),
        hostMonitoringEnabled: @escaping () -> Bool = { true },
        clusterProbe: any ClusterHealthProbing = LiveClusterHealthProbe(),
        clusterHealthEnabled: @escaping () -> Bool = { false }
    ) {
        self.runner = runner
        self.notifier = notifier
        self.appController = appController
        self.reaper = reaper
        self.portInspector = portInspector
        self.policy = policy
        self.maxLogLines = maxLogLines
        self.appQuitTimeout = appQuitTimeout
        self.vmProbe = vmProbe
        self.isVMMonitoringEnabled = vmMonitoringEnabled
        self.minikubeProbe = minikubeProbe
        self.oomInspector = oomInspector
        self.isMinikubeMonitoringEnabled = minikubeMonitoringEnabled
        self.hostProbe = hostProbe
        self.isHostMonitoringEnabled = hostMonitoringEnabled
        self.clusterProbe = clusterProbe
        self.isClusterHealthEnabled = clusterHealthEnabled
    }

    /// Prod default: the real zsh/sudo router + a live app controller.
    convenience init(maxLogLines: Int = 2000) {
        self.init(runner: RoutingCommandRunner(), maxLogLines: maxLogLines)
    }

    // MARK: commands

    /// Run a command from the UI. A daemon with a known `port` goes through a proactive
    /// occupied-port check first; everything else launches directly.
    /// Chain steps bypass this (they call `startRun`) — the reactive check covers them.
    func run(_ command: Command) {
        portConflicts[command.id] = nil   // a fresh run clears a stale panel
        guard command.isDaemon, let port = command.port,
              active[command.id] == nil, adoptedPIDs[command.id] == nil else {
            // Restart-over-self needs no pre-check: startRun preempts our own port holder.
            launch(command)
            return
        }
        states[command.id] = .running   // immediate spinner while lsof runs
        let precheckToken = UUID()
        portPrecheckTokens[command.id] = precheckToken
        Task { @MainActor [weak self] in
            guard let self else { return }
            let occupant = await self.checkPort(port)
            guard self.portPrecheckTokens[command.id] == precheckToken else { return }
            self.portPrecheckTokens[command.id] = nil
            if let occupant {
                self.states[command.id] = .idle
                self.portConflicts[command.id] = PortConflict(port: port, occupant: occupant, command: command)
                DiagnosticLog.shared.log(
                    "Port \(port) is occupied by \(occupant.processName) (PID \(occupant.pid)) — “\(command.name)” not started",
                    level: .warn)
            } else {
                self.launch(command)
            }
        }
    }

    /// Launch without the port pre-check. With a non-empty `appsToQuit` — memory freeing:
    /// gently quit the apps → run → on the terminal event (always) relaunch the closed ones.
    private func launch(_ command: Command) {
        guard !command.appsToQuit.isEmpty else {
            startRun(command)
            return
        }
        // Memory freeing: quit → run → relaunch. The token prevents a restart from producing
        // a "stale" relaunch of the old run that fights the new one.
        // (Daemon + appsToQuit: the relaunch fires when daemonRunning is reached, not on stop —
        //  a secondary case; the main use of the feature is finishing commands/chains.)
        let memoryToken = UUID()
        memoryTokens[command.id] = memoryToken
        Task { @MainActor [weak self] in
            guard let self else { return }
            let closed = await self.quitApps(command.appsToQuit, for: command.id)
            _ = await self.awaitRun(command)
            guard self.memoryTokens[command.id] == memoryToken else { return }   // preempted — don't relaunch
            self.relaunchApps(closed, for: command.id)
        }
    }

    /// Start a run without memory orchestration. Returns the token (for a chain step),
    /// or nil if the launch is rejected (sudo daemon).
    @discardableResult
    private func startRun(_ command: Command, isWatchdogRestart: Bool = false) -> UUID? {
        // Hard rule: a sudo daemon is impossible (no stream/pid/stop).
        guard !(command.needsSudo && command.isDaemon) else {
            logs[command.id] = RingBuffer(capacity: maxLogLines)
            appendLog(command.id, L10n.sudoDaemonUnsupported, .stderr)
            states[command.id] = .failed(code: -1)
            DiagnosticLog.shared.log("Rejected: sudo daemon “\(command.name)”", level: .error)
            return nil
        }

        // Proxy routing: a flagged command must egress through the LAN proxy. If none resolves,
        // fail LOUDLY — launching it directly would leak the traffic past the VPN, which is exactly
        // what the flag exists to prevent. Applied here, the single `runner.start` call site, so
        // zsh/sudo/terminal runs are all covered (they each read `command.env`).
        var effective = command
        if command.routeThroughProxy {
            switch proxyRouting(command) {
            case .unavailable:
                logs[command.id] = RingBuffer(capacity: maxLogLines)
                appendLog(command.id, L10n.proxyUnavailable, .stderr)
                states[command.id] = .failed(code: Self.proxyUnavailableCode)
                DiagnosticLog.shared.log("Proxy unavailable — “\(command.name)” not started", level: .error)
                notifier.post(.proxyUnavailable(name: command.name))
                return nil
            case .routed(let env):
                effective.env.merge(env) { _, new in new }
            case .notRouted:
                break
            }
        }

        if command.isDaemon {
            lastStarted[command.id] = command
            if command.watchdogEnabled {
                // A fresh user start (direct or chain step) begins a new attempt series;
                // a watchdog restart keeps counting toward the give-up limit.
                if !isWatchdogRestart { watchdogFailures[command.id] = 0 }
                watchdogArmed.insert(command.id)
                watchdogPhases[command.id] = .armed
            }
        }

        // A restart PREEMPTS the previous run of the same id.
        if let old = active[command.id] {
            // If this command is a live chain step, wake its driver: otherwise cancelling the
            // consumer below would cut off the event path and the chain would hang forever.
            resumeStep(token: old.token, .cancelled)
            old.stop()
            consumers[command.id]?.cancel()
        }

        // If this command is currently "adopted" (a daemon from a previous session), kill its subtree
        // before the new run, otherwise the new process would fight the old one over the port (and
        // adoptedPIDs would stay stale). The entry will be overwritten by the new start.
        if let adoptedPID = adoptedPIDs.removeValue(forKey: command.id) {
            DiagnosticLog.shared.log(
                "Restart over an adopted process: killing PID \(adoptedPID) [\(command.id.uuidString.prefix(8))]")
            reaper.killTree(pid: adoptedPID)
        }

        stopRequested.remove(command.id)
        logs[command.id] = RingBuffer(capacity: maxLogLines)
        states[command.id] = .running

        let handle = runner.start(effective)
        active[command.id] = handle

        let token = handle.token
        let id = command.id
        let isDaemon = command.isDaemon
        let name = command.name
        DiagnosticLog.shared.log("Start “\(name)” [\(id.uuidString.prefix(8))]"
            + (isDaemon ? " daemon" : "") + (command.needsSudo ? " sudo" : ""))
        // @MainActor explicitly: the real runner emits events from background queues; without this,
        // under Swift 5 mode `apply` could mutate @Observable state off the main thread → a SwiftUI
        // crash. All state mutations must run on main.
        consumers[id] = Task { @MainActor [weak self] in
            for await event in handle.output {
                self?.apply(event, token: token, commandID: id, isDaemon: isDaemon, name: name)
            }
        }
        return token
    }

    /// Stop a run. The terminal event arrives as a stream EVENT (single source of truth);
    /// we mark it as a user stop so it isn't shown red ("error").
    /// An adopted daemon (no managed Process) is killed by PID subtree.
    func stop(_ commandID: UUID) {
        // A user stop never restarts: deactivate watching (the persisted flag is untouched —
        // the next manual start re-arms).
        deactivateWatchdog(commandID)
        if let pid = adoptedPIDs[commandID] {
            DiagnosticLog.shared.log("Stop adopted daemon PID \(pid) [\(commandID.uuidString.prefix(8))]")
            reaper.killTree(pid: pid)
            adoptedPIDs.removeValue(forKey: commandID)
            states[commandID] = .idle
            return
        }
        stopRequested.insert(commandID)
        active[commandID]?.stop()
    }

    /// Clear the log buffer (the "Clear" button in LogView).
    func clearLog(_ id: UUID) {
        logs[id] = RingBuffer(capacity: maxLogLines)
    }

    // MARK: chains

    /// Run a chain. A single driver Task walks `commandIDs` sequentially,
    /// awaiting each step's terminal event (or `daemonRunning`) before starting the next.
    /// A repeated run collapses an unfinished run of the same chain.
    func run(_ chain: Chain, commands: [UUID: Command]) {
        DiagnosticLog.shared.log("Run chain “\(chain.name)” (\(chain.commandIDs.count) steps)")
        if chain.openInTerminal {
            runChainInTerminal(chain, commands: commands)
            return
        }
        // Stop the current step (its terminal event wakes the old suspended driver →
        // it sees the token change and collapses, without leaking a continuation) and cancel the driver.
        if let current = chainCurrentCommand[chain.id] {
            active[current]?.stop()
        }
        chainTasks[chain.id]?.cancel()

        let token = UUID()
        chainTokens[chain.id] = token
        chainCurrentCommand[chain.id] = nil
        chainStates[chain.id] = .running(currentIndex: 0)
        chainTasks[chain.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            // Chain-level memory freeing: quit the UNION of all steps' apps once before,
            // relaunch once after (steps don't quit apps individually).
            let closed = await self.quitApps(self.unionAppsToQuit(chain, commands), for: chain.id)
            await self.driveChain(chain, token: token, commands: commands)
            guard self.chainTokens[chain.id] == token else { return }   // preempted by a new run — don't relaunch
            self.relaunchApps(closed, for: chain.id)
        }
    }

    /// Run the whole chain as ONE script in a single terminal tab. The status is coarse
    /// (running → succeeded/failed/stopped); detailed progress is in the tab. The run is
    /// keyed by `chain.id` (in `active`/`consumers`); stop kills the whole tab (`killTree`).
    private func runChainInTerminal(_ chain: Chain, commands: [UUID: Command]) {
        // Preempt the previous run of this chain (any mode).
        if let current = chainCurrentCommand[chain.id] { active[current]?.stop() }
        chainTasks[chain.id]?.cancel()
        if active[chain.id] != nil { active[chain.id]?.stop(); consumers[chain.id]?.cancel() }

        stopRequested.remove(chain.id)
        logs[chain.id] = RingBuffer(capacity: maxLogLines)
        chainStates[chain.id] = .running(currentIndex: 0)

        let body = ChainScript.build(chain, commands: commands)
        let virtual = Command(id: chain.id, name: chain.name, command: body, openInTerminal: true)
        let handle = runner.start(virtual)
        active[chain.id] = handle

        let token = handle.token
        let id = chain.id
        let name = chain.name
        consumers[id] = Task { @MainActor [weak self] in
            for await event in handle.output {
                self?.applyChainTerminal(event, token: token, chainID: id, name: name)
            }
        }
    }

    private func applyChainTerminal(_ event: RunnerOutput, token: UUID, chainID: UUID, name: String) {
        assert(Thread.isMainThread, "applyChainTerminal must run on the main thread")
        guard active[chainID]?.token == token else { return }
        switch event {
        case .started(let pid):
            if let pid { buildPIDs[chainID] = pid }
            startVMSamplerIfNeeded()   // the chain is already .running; the sampler is needed from the first event
        case .line(let text, let stream):
            appendLog(chainID, text, stream)
        case .terminated(let code):
            active[chainID] = nil
            consumers[chainID] = nil
            flushRunPeaks(chainID, name: name)
            if stopRequested.remove(chainID) != nil {
                chainStates[chainID] = .stopped
                DiagnosticLog.shared.log("Chain stopped by user: “\(name)”")
            } else if code == 0 {
                chainStates[chainID] = .succeeded
                DiagnosticLog.shared.log("Chain finished: “\(name)”")
            } else {
                chainStates[chainID] = .failed(atIndex: 0, code: code)
                DiagnosticLog.shared.log("Chain failed: “\(name)” code \(code)", level: .warn)
                notifier.post(.commandFailed(name: name, code: code))
                scanOOMIfNeeded(after: name, code: code)
                if isHostMonitoringEnabled() {
                    let tail = logs[chainID]?.elements.suffix(40).map(\.text).joined(separator: "\n") ?? ""
                    let verdict = detectOOM(exitCode: code, logTail: tail)
                    if verdict.isOOM {
                        let crate = verdict.crate.map { " · crate `\($0)`" } ?? ""
                        DiagnosticLog.shared.log("Likely OOM in chain “\(name)” (signal 9 / SIGKILL)\(crate)", level: .warn)
                    } else if let c = verdict.crate {
                        DiagnosticLog.shared.log("Chain “\(name)” failed at crate `\(c)`", level: .warn)
                    }
                }
            }
        case .cancelled:
            active[chainID] = nil
            consumers[chainID] = nil
            stopRequested.remove(chainID)
            flushRunPeaks(chainID, name: name)
            chainStates[chainID] = .stopped
        }
    }

    /// Stop a chain: cancel the driver and stop the current step. The current step's terminal
    /// event wakes the driver, which sees the cancellation and sets `.stopped`. Daemons raised
    /// earlier are NOT touched — they keep running. Chain-in-terminal: kill the whole tab.
    func stopChain(_ chainID: UUID) {
        chainTasks[chainID]?.cancel()
        if active[chainID] != nil {   // chain-in-terminal: a single run under chainID
            stopRequested.insert(chainID)
            active[chainID]?.stop()
            return
        }
        if let current = chainCurrentCommand[chainID] {
            stopRequested.insert(current)
            active[current]?.stop()
        }
    }

    private func driveChain(_ chain: Chain, token: UUID, commands: [UUID: Command]) async {
        defer { if chainTokens[chain.id] == token { chainCurrentCommand[chain.id] = nil } }

        var lastFailure: (index: Int, code: Int32)?
        for (index, commandID) in chain.commandIDs.enumerated() {
            guard chainTokens[chain.id] == token else { return }   // preempted by a new run
            if Task.isCancelled { setChain(chain.id, .stopped, token); return }

            guard let command = commands[commandID] else {
                setChain(chain.id, .failed(atIndex: index, code: Self.missingCommandCode), token)
                return
            }

            setChain(chain.id, .running(currentIndex: index), token)
            chainCurrentCommand[chain.id] = commandID
            let outcome = await awaitRun(command)

            guard chainTokens[chain.id] == token else { return }   // preempted during the await
            if Task.isCancelled { setChain(chain.id, .stopped, token); return }

            switch outcome {
            case .succeeded, .daemonRunning:
                continue
            case .cancelled:
                setChain(chain.id, .stopped, token)
                return
            case .failed(let code):
                if chain.stopOnError {
                    setChain(chain.id, .failed(atIndex: index, code: code), token)
                    return
                }
                lastFailure = (index, code)   // remember it, but keep going
            }
        }
        setChain(chain.id, lastFailure.map { .failed(atIndex: $0.index, code: $0.code) } ?? .succeeded, token)
    }

    private func setChain(_ id: UUID, _ state: ChainState, _ token: UUID) {
        guard chainTokens[id] == token else { return }
        chainStates[id] = state
    }

    /// Start a run and await its terminal/daemon-start (for a chain step and a direct run with
    /// memory freeing). The resume comes from `apply` keyed by the run's token.
    private func awaitRun(_ command: Command) async -> StepOutcome {
        await withCheckedContinuation { continuation in
            if let token = startRun(command), active[command.id]?.token == token {
                stepWaiters[token] = continuation
            } else {
                continuation.resume(returning: .failed(code: -1))   // rejected (sudo daemon)
            }
        }
    }

    private func resumeStep(token: UUID, _ outcome: StepOutcome) {
        stepWaiters.removeValue(forKey: token)?.resume(returning: outcome)
    }

    // MARK: memory freeing

    private func quitApps(_ apps: [AppRef], for id: UUID) async -> [AppRef] {
        guard !apps.isEmpty else { return [] }
        appendLog(id, L10n.freeingMemoryClosing(apps.map(\.name).joined(separator: ", ")), .stdout)
        let closedIDs = Set(await appController.quit(apps.map(\.bundleID), timeout: appQuitTimeout))
        let notClosed = apps.filter { !closedIDs.contains($0.bundleID) }
        if !notClosed.isEmpty {
            appendLog(id, L10n.didNotClose(notClosed.map(\.name).joined(separator: ", ")), .stderr)
        }
        let closed = apps.filter { closedIDs.contains($0.bundleID) }
        DiagnosticLog.shared.log("Memory: closed [\(closed.map(\.name).joined(separator: ", "))]"
            + (notClosed.isEmpty ? "" : "; did not close [\(notClosed.map(\.name).joined(separator: ", "))]"))
        return closed
    }

    private func relaunchApps(_ apps: [AppRef], for id: UUID) {
        guard !apps.isEmpty else { return }
        appController.relaunch(apps.map(\.bundleID))
        appendLog(id, L10n.relaunchingApps(apps.map(\.name).joined(separator: ", ")), .stdout)
        DiagnosticLog.shared.log("Memory: relaunching [\(apps.map(\.name).joined(separator: ", "))]")
    }

    /// Union of `appsToQuit` across all chain steps, in order of appearance, without duplicates.
    private func unionAppsToQuit(_ chain: Chain, _ commands: [UUID: Command]) -> [AppRef] {
        var seen = Set<String>()
        var result: [AppRef] = []
        for commandID in chain.commandIDs {
            for app in commands[commandID]?.appsToQuit ?? [] where seen.insert(app.bundleID).inserted {
                result.append(app)
            }
        }
        return result
    }

    // MARK: port conflicts

    /// "Kill & start" from the conflict panel: SIGTERM the occupant's subtree, wait for the
    /// port to free (SIGKILL escalation if it doesn't), then launch our daemon.
    func killOccupantAndStart(_ commandID: UUID) {
        guard var conflict = portConflicts[commandID], !conflict.resolving else { return }
        conflict.resolving = true
        portConflicts[commandID] = conflict
        let occupant = conflict.occupant
        let port = conflict.port
        let command = conflict.command
        DiagnosticLog.shared.log("Port \(port): killing occupant \(occupant.processName) (PID \(occupant.pid))")
        reaper.killTree(pid: occupant.pid)
        Task { @MainActor [weak self] in
            guard let self else { return }
            var freed = await self.awaitPortFree(port)
            if !freed {
                DiagnosticLog.shared.log(
                    "Port \(port) still occupied after SIGTERM — escalating to SIGKILL (PID \(occupant.pid))",
                    level: .warn)
                self.reaper.forceKillTree(pid: occupant.pid)
                freed = await self.awaitPortFree(port)
            }
            // The user may have dismissed the panel while we waited.
            guard self.portConflicts[commandID]?.resolving == true else { return }
            if freed {
                self.portConflicts[commandID] = nil
                if self.watchdogArmed.contains(commandID) { self.watchdogPhases[commandID] = .armed }
                self.startRun(command)
            } else {
                self.portConflicts[commandID]?.resolving = false
                self.appendLog(commandID, L10n.portStillOccupied(port, occupant.processName, occupant.pid), .stderr)
                DiagnosticLog.shared.log("Port \(port) could not be freed (PID \(occupant.pid))", level: .error)
            }
        }
    }

    /// "Cancel" from the conflict panel: don't start; a paused watchdog stays off
    /// until the next manual start (the persisted flag is untouched).
    func dismissPortConflict(_ commandID: UUID) {
        portConflicts[commandID] = nil
        if watchdogPhases[commandID] == .pausedOnConflict {
            deactivateWatchdog(commandID)
        }
    }

    /// lsof off the main thread (it blocks for ~100 ms).
    private func checkPort(_ port: Int) async -> PortOccupant? {
        let inspector = portInspector
        return await Task.detached(priority: .userInitiated) { inspector.occupant(ofPort: port) }.value
    }

    /// Poll until the port frees or the per-phase timeout expires.
    private func awaitPortFree(_ port: Int) async -> Bool {
        let deadline = ContinuousClock.now + policy.portFreeTimeout
        while ContinuousClock.now < deadline {
            if await checkPort(port) == nil { return true }
            try? await Task.sleep(for: policy.portFreePollInterval)
        }
        return await checkPort(port) == nil
    }

    /// After a daemon failed to start: if its port is occupied, surface the conflict panel
    /// under the red row (covers chain steps and races the pre-check can't see).
    private func startReactivePortCheck(_ commandID: UUID, port: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let occupant = await self.checkPort(port) else { return }
            // Surface only if the daemon is still down and nothing else took over.
            guard self.active[commandID] == nil, self.adoptedPIDs[commandID] == nil,
                  self.portConflicts[commandID] == nil,
                  let command = self.lastStarted[commandID] else { return }
            self.portConflicts[commandID] = PortConflict(port: port, occupant: occupant, command: command)
            DiagnosticLog.shared.log(
                "Port \(port) is occupied by \(occupant.processName) (PID \(occupant.pid)) — “\(command.name)” failed to start",
                level: .warn)
        }
    }

    // MARK: daemon watchdog

    /// Arm from the popover shield: watch a live/adopted daemon, or start it and watch.
    func armWatchdog(_ command: Command) {
        var armed = command
        armed.watchdogEnabled = true
        if active[armed.id] != nil || adoptedPIDs[armed.id] != nil {
            lastStarted[armed.id] = armed
            watchdogFailures[armed.id] = 0
            watchdogArmed.insert(armed.id)
            watchdogPhases[armed.id] = .armed
            startAdoptedWatchdogPollIfNeeded()
        } else {
            run(armed)   // startRun arms via the watchdogEnabled flag
        }
    }

    /// Disarm from the popover shield; the daemon itself keeps running.
    func disarmWatchdog(_ commandID: UUID) {
        deactivateWatchdog(commandID)
    }

    /// Stop watching: cancel pending restart/stability tasks and clear the phase.
    private func deactivateWatchdog(_ commandID: UUID) {
        watchdogRestartTasks.removeValue(forKey: commandID)?.cancel()
        stabilityTasks.removeValue(forKey: commandID)?.cancel()
        watchdogArmed.remove(commandID)
        watchdogPhases[commandID] = nil
        watchdogFailures[commandID] = nil
    }

    /// Restart after an unexpected daemon death: counted attempts with growing pauses;
    /// the limit exhausted → `gaveUp` + notification. A stable run resets the counter.
    private func scheduleWatchdogRestart(_ commandID: UUID) {
        guard watchdogArmed.contains(commandID), let command = lastStarted[commandID] else { return }
        let attempt = (watchdogFailures[commandID] ?? 0) + 1
        watchdogFailures[commandID] = attempt
        guard attempt <= policy.restartDelays.count else {
            watchdogPhases[commandID] = .gaveUp
            watchdogArmed.remove(commandID)
            DiagnosticLog.shared.log(
                "Watchdog: “\(command.name)” keeps dying — giving up after \(policy.restartDelays.count) restarts",
                level: .error)
            notifier.post(.watchdogGaveUp(name: command.name))
            return
        }
        watchdogPhases[commandID] = .restarting(attempt: attempt)
        let delay = policy.restartDelays[attempt - 1]
        watchdogRestartTasks[commandID]?.cancel()
        watchdogRestartTasks[commandID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.watchdogRestartTasks[commandID] = nil
            // The user may have stopped or restarted the daemon manually during the pause.
            guard self.watchdogArmed.contains(commandID),
                  self.active[commandID] == nil, self.adoptedPIDs[commandID] == nil else { return }
            if let port = command.port {
                // "Kill & start" already in flight — it will launch when the port frees.
                if self.portConflicts[commandID]?.resolving == true { return }
                let occupant = await self.checkPort(port)
                // Re-check: the world may have changed while lsof ran.
                guard self.watchdogArmed.contains(commandID),
                      self.active[commandID] == nil, self.adoptedPIDs[commandID] == nil,
                      self.portConflicts[commandID]?.resolving != true else { return }
                if let occupant {
                    // A foreign port owner: retries are futile — pause and ask the user.
                    self.watchdogPhases[commandID] = .pausedOnConflict
                    self.portConflicts[commandID] = PortConflict(port: port, occupant: occupant, command: command)
                    DiagnosticLog.shared.log(
                        "Watchdog: port \(port) is occupied by \(occupant.processName) (PID \(occupant.pid)) — pausing “\(command.name)”",
                        level: .warn)
                    return
                }
            }
            DiagnosticLog.shared.log("Watchdog: restarting “\(command.name)” (attempt \(attempt))")
            self.startRun(command, isWatchdogRestart: true)
        }
    }

    /// Reset the failure counter once the daemon has stayed up for the stability window.
    private func startStabilityTask(_ commandID: UUID, token: UUID) {
        stabilityTasks[commandID]?.cancel()
        let window = policy.stabilityWindow
        stabilityTasks[commandID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: window)
            guard let self, !Task.isCancelled else { return }
            self.stabilityTasks[commandID] = nil
            // Token guard: a preempted run's timer must not reset the next run's counter.
            guard self.active[commandID]?.token == token,
                  self.states[commandID] == .daemonRunning else { return }
            self.watchdogFailures[commandID] = 0
            if self.watchdogArmed.contains(commandID) { self.watchdogPhases[commandID] = .armed }
        }
    }

    /// Adopted daemons have no output stream — liveness is polled by PID (cheap `kill(pid, 0)`).
    /// One task for all adopted daemons; exits when none are watched, restarted on adopt/arm.
    private func startAdoptedWatchdogPollIfNeeded() {
        guard adoptedPollTask == nil,
              adoptedPIDs.contains(where: { watchdogArmed.contains($0.key) }) else { return }
        let interval = policy.adoptedPollInterval
        adoptedPollTask = Task { @MainActor [weak self] in
            while let self {
                let watched = self.adoptedPIDs.filter { self.watchdogArmed.contains($0.key) }
                if watched.isEmpty { break }
                for (id, pid) in watched where !self.reaper.isAlive(pid: pid) {
                    self.adoptedPIDs.removeValue(forKey: id)
                    self.states[id] = .failed(code: -1)
                    let name = self.lastStarted[id]?.name ?? id.uuidString
                    DiagnosticLog.shared.log("Watchdog: adopted daemon “\(name)” (PID \(pid)) died", level: .warn)
                    self.scheduleWatchdogRestart(id)
                }
                try? await Task.sleep(for: interval)
            }
            self?.adoptedPollTask = nil
        }
    }

    // MARK: adopting daemons after a restart

    /// Adopt daemons that survived a previous session. For each daemon command we look for an
    /// ORPHANED process (reparented to launchd) with the same command. Matching by command is
    /// robust to legacy orphans and crashes (doesn't depend on a saved PID). The one found is
    /// shown as `daemonRunning` ("adopted"); stop kills its subtree and frees the port.
    func adoptSurvivingDaemons(commands: [UUID: Command]) {
        for command in commands.values where command.isDaemon {
            guard states[command.id] == nil, adoptedPIDs[command.id] == nil else { continue }
            guard let pid = reaper.findOrphan(matchingCommand: command.command) else { continue }
            states[command.id] = .daemonRunning
            adoptedPIDs[command.id] = pid
            lastStarted[command.id] = command
            if command.watchdogEnabled {
                // The persisted flag survives the app restart — the adopted daemon auto-arms.
                watchdogFailures[command.id] = 0
                watchdogArmed.insert(command.id)
                watchdogPhases[command.id] = .armed
            }
            DiagnosticLog.shared.log("Adopted daemon: “\(command.name)” PID \(pid)")
            notifier.post(.daemonAdopted(name: command.name))
        }
        startAdoptedWatchdogPollIfNeeded()
    }

    // MARK: for the exit dialog (Stage 5)

    var aliveDaemons: [UUID] {
        states.compactMap { $0.value == .daemonRunning ? $0.key : nil }
    }

    func hasLiveDaemons() -> Bool {
        states.values.contains(.daemonRunning)
    }

    // MARK: VM sampler methods

    /// VM snapshot for the popover — returns the cache without blocking (gated by the flag).
    func vmMemorySample() -> VMMemoryInfo? { cachedVMSample }

    /// minikube snapshot for the popover — the sampler cache, present only during a run.
    func minikubeSample() -> MinikubeSample? { cachedMinikubeSample }

    /// Proactively warn (banner + log) when a VM/node memory layer crosses the danger threshold
    /// during a run, so you don't have to watch the popover. Debounced to once per layer per run.
    func checkMemoryThresholds(vm: VMMemoryInfo?, minikube: MinikubeSample?) {
        if let vm, vm.fraction >= memoryWarnThreshold, warnedThresholds.insert("colima").inserted {
            notifier.post(.memoryThreshold(target: "colima", detail: vm.format()))
            DiagnosticLog.shared.log("colima memory high: \(vm.format())", level: .warn)
        }
        if let mk = minikube, mk.fraction >= memoryWarnThreshold, warnedThresholds.insert("minikube").inserted {
            notifier.post(.memoryThreshold(target: "minikube", detail: mk.format()))
            DiagnosticLog.shared.log("minikube memory high: \(mk.format())", level: .warn)
        }
    }

    /// Probe colima + minikube health OFF the main thread and publish it for the popover.
    /// No-op (and clears the cache) when disabled. Called while the popover is open.
    func refreshClusterHealth() async {
        guard isClusterHealthEnabled() else { cachedClusterHealth = nil; return }
        let probe = clusterProbe
        cachedClusterHealth = await Task.detached(priority: .utility) { probe.sample() }.value
    }

    /// Resolve live colima cpus/limit for the `-j` advisory, OFF the main thread. Cached once known.
    func refreshVMBuildConfig() {
        if vmBuildConfig != nil { return }
        let probe = vmProbe
        Task { @MainActor [weak self] in
            let cfg = await Task.detached(priority: .utility) { probe.buildConfig() }.value
            if let cfg { self?.vmBuildConfig = cfg }
        }
    }

    /// Update cachedVMSample by running the blocking probe OFF the main thread.
    func refreshVMSample() async {
        guard isVMMonitoringEnabled() else { cachedVMSample = nil; return }
        let probe = vmProbe
        let s = await Task.detached(priority: .utility) { probe.sample() }.value
        cachedVMSample = s   // back on the MainActor after the await — the assignment is on main
    }

    /// A single VM-RSS sample for run id (called from tests). Synchronous, don't touch.
    func recordVMSample(for id: UUID) {
        guard isVMMonitoringEnabled(), let s = vmProbe.sample() else { return }
        accumulateVMPeak(s, for: id)
    }

    /// Pure peak accumulator without sampling — called from the sampler task.
    private func accumulateVMPeak(_ s: VMMemoryInfo, for id: UUID) {
        if let prev = vmPeak[id], prev.usedBytes >= s.usedBytes { return }
        vmPeak[id] = s
    }

    func vmPeakBytes(for id: UUID) -> UInt64? { vmPeak[id]?.usedBytes }

    /// One host sample for run id (called from tests). Synchronous.
    func recordHostSample(for id: UUID) {
        guard isHostMonitoringEnabled() else { return }
        let s = hostProbe.sample(buildPID: buildPIDs[id])
        accumulateHostPeak(s, for: id)
    }

    func hostPeakFootprint(for id: UUID) -> UInt64? { hostPeak[id] }

    /// The build PID captured from the last `.started` event for a run (nil when not yet received).
    func buildPID(for id: UUID) -> Int32? { buildPIDs[id] }

    private func accumulateHostPeak(_ s: HostMetricsSample, for id: UUID) {
        hostStats[id] = s
        if s.buildFootprintBytes > (hostPeak[id] ?? 0) { hostPeak[id] = s.buildFootprintBytes }
    }

    /// Compute the live swap-out rate from the previous sample and publish it for the popover.
    /// The first call (no predecessor) only records the baseline and leaves the rate nil.
    func updateSwapRate(cur: HostMetricsSample, now: Date) {
        if let prev = prevHostForRate {
            let dt = now.timeIntervalSince(prev.time)
            let rate = swapRatePagesPerSec(prevIn: prev.sample.swapInsPages, prevOut: prev.sample.swapOutsPages,
                                           curIn: cur.swapInsPages, curOut: cur.swapOutsPages, dtSeconds: dt)
            cachedSwapOutRatePages = rate.outPerSec
            cachedSwapInRatePages = rate.inPerSec
        }
        prevHostForRate = (cur, now)
    }

    /// A single minikube sample for run id (called from tests). Synchronous.
    func recordMinikubeSample(for id: UUID) {
        guard isMinikubeMonitoringEnabled(), let s = minikubeProbe.sample() else { return }
        absorbMinikube(s, for: id)
    }

    func minikubeRunStats(for id: UUID) -> MinikubeRunStats? { minikubeStats[id] }

    private func absorbMinikube(_ s: MinikubeSample, for id: UUID) {
        if var stats = minikubeStats[id] {
            stats.absorb(s)
            minikubeStats[id] = stats
        } else {
            minikubeStats[id] = MinikubeRunStats(first: s)
        }
    }

    /// Build PID to footprint for host metrics: prefer a currently-running command/chain's
    /// captured PID, with a stable tiebreak (sorted by id). nil if none captured yet.
    private var primaryBuildPID: Int32? {
        let runningIDs = active.keys.filter { id in
            if states[id] == .running { return true }
            if case .running = chainStates[id] { return true }
            return false
        }.sorted { $0.uuidString < $1.uuidString }
        if let id = runningIDs.first(where: { buildPIDs[$0] != nil }) { return buildPIDs[id] }
        return buildPIDs.min(by: { $0.key.uuidString < $1.key.uuidString })?.value
    }

    /// Runs worth probing minikube for: actively RUNNING commands and chains-in-terminal.
    /// Hanging daemons are excluded — otherwise the ssh probe would hammer for hours.
    private var minikubeTargetIDs: [UUID] {
        active.keys.filter { id in
            if states[id] == .running { return true }
            if case .running = chainStates[id] { return true }
            return false
        }
    }

    /// Log and clear the per-run peaks (on the terminal event) — colima and minikube.
    private func flushRunPeaks(_ id: UUID, name: String) {
        flushVMPeak(id, name: name)
        flushMinikubeStats(id, name: name)
        flushHostStats(id, name: name)
    }

    /// Log and clear the per-run peak (on the terminal event).
    private func flushVMPeak(_ id: UUID, name: String) {
        guard let peak = vmPeak.removeValue(forKey: id) else { return }
        let headroom = Int((peak.headroomFraction * 100).rounded())
        var hint = ""
        if peak.headroomFraction > 0.30 { hint = " — colima --memory could be lowered" }
        else if peak.headroomFraction < 0.10 { hint = " — tight, raise colima --memory" }
        DiagnosticLog.shared.log("VM peak for “\(name)”: \(peak.format()) (headroom \(headroom)%)\(hint)")
    }

    private func flushMinikubeStats(_ id: UUID, name: String) {
        guard let stats = minikubeStats.removeValue(forKey: id) else { return }
        let peak = stats.peak
        let headroom = Int((peak.headroomFraction * 100).rounded())
        var line = "minikube peak for “\(name)”: \(peak.format()) (headroom \(headroom)%)"
        if stats.maxRustcCount > 0 {
            line += " · rustc max \(stats.maxRustcCount), RSS max \(SystemMemory.formatGiB(stats.maxRustcRSSBytes))"
        }
        if peak.headroomFraction > 0.30 { line += " — minikube --memory could be lowered" }
        else if peak.headroomFraction < 0.10 { line += " — tight, raise minikube --memory" }
        DiagnosticLog.shared.log(line)
    }

    private func flushHostStats(_ id: UUID, name: String) {
        defer { hostPeak.removeValue(forKey: id); hostStats.removeValue(forKey: id); buildPIDs.removeValue(forKey: id) }
        let peak = hostPeak[id] ?? 0
        let last = hostStats[id]
        guard peak > 0 || last != nil else { return }
        let gib = 1_073_741_824.0
        var parts: [String] = []
        // For nested builds the host can't see rustc (it runs inside the VM), so a sub-0.1 GiB
        // footprint is just the shell wrapper — omit the misleading "build RSS 0.0 GB".
        if Double(peak) / gib >= 0.1 {
            parts.append("build RSS " + String(format: "%.1f GB", Double(peak) / gib))
        }
        if let last {
            let pressure: String
            switch last.pressure {
            case .normal: pressure = "normal"
            case .warning: pressure = "warning"
            case .critical: pressure = "critical"
            }
            parts.append("pressure \(pressure)")
            let compFrac = Int((last.compressorFraction(pageSize: hostPageSize) * 100).rounded())
            if compFrac > 0 { parts.append("compressor \(compFrac)%") }
        }
        guard !parts.isEmpty else { return }
        DiagnosticLog.shared.log("Host summary for \u{201c}\(name)\u{201d}: " + parts.joined(separator: " · "),
                                 level: last?.pressure == .critical ? .warn : .info)
    }

    /// After a failed run (not a user stop) — detect OOM kills:
    /// kubectl (OOMKilled pods) + the node's dmesg. The blocking scan runs off the main thread.
    private func scanOOMIfNeeded(after name: String, code: Int32) {
        guard isMinikubeMonitoringEnabled() else { return }
        let inspector = oomInspector
        Task { @MainActor [weak self] in
            let report = await Task.detached(priority: .utility) { inspector.scan() }.value
            guard self != nil, !report.isEmpty else { return }
            for e in report.events {
                DiagnosticLog.shared.log(
                    "OOMKilled: \(e.namespace)/\(e.pod) container \(e.container), restarts \(e.restartCount)"
                        + (e.finishedAt.map { ", \($0)" } ?? "") + " (after the failure of “\(name)”, code \(code))",
                    level: .warn)
            }
            for line in report.dmesgLines {
                DiagnosticLog.shared.log("dmesg OOM: \(line)", level: .warn)
            }
        }
    }

    private func startVMSamplerIfNeeded() {
        guard vmSamplerTask == nil,
              isVMMonitoringEnabled() || isMinikubeMonitoringEnabled() || isHostMonitoringEnabled() else { return }
        vmSamplerTask = Task { @MainActor [weak self] in
            while let self, !self.active.isEmpty {
                let vmProbe = self.isVMMonitoringEnabled() ? self.vmProbe : nil
                let mkTargets = self.isMinikubeMonitoringEnabled() ? self.minikubeTargetIDs : []
                let mkProbe = mkTargets.isEmpty ? nil : self.minikubeProbe
                let (s, mk) = await Task.detached(priority: .utility) {
                    (vmProbe?.sample(), mkProbe?.sample())
                }.value
                self.cachedVMSample = s
                if let s { for id in self.active.keys { self.accumulateVMPeak(s, for: id) } }
                self.cachedMinikubeSample = mk
                if let mk { for id in mkTargets where self.active[id] != nil { self.absorbMinikube(mk, for: id) } }
                self.checkMemoryThresholds(vm: s, minikube: mk)
                if self.isHostMonitoringEnabled() {
                    let pid = self.primaryBuildPID
                    let hostProbe = self.hostProbe
                    let host = await Task.detached(priority: .utility) {
                        hostProbe.sample(buildPID: pid)
                    }.value
                    self.cachedHostSample = host
                    self.updateSwapRate(cur: host, now: Date())
                    for id in self.active.keys { self.accumulateHostPeak(host, for: id) }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            self?.vmSamplerTask = nil
            self?.cachedMinikubeSample = nil   // outside a run the minikube line isn't shown in the popover
            self?.cachedHostSample = nil
            self?.cachedSwapOutRatePages = nil
            self?.cachedSwapInRatePages = nil
            self?.prevHostForRate = nil
            self?.warnedThresholds.removeAll()
        }
    }

    // MARK: single mutator (always on main)

    private func apply(_ event: RunnerOutput, token: UUID, commandID: UUID, isDaemon: Bool, name: String) {
        // Regression guard for the off-main fix: every @Observable mutation must run on main.
        assert(Thread.isMainThread, "ProcessManager.apply must run on the main thread")

        // Guard against a "late" event from a run preempted by a restart.
        guard active[commandID]?.token == token else { return }

        let tag = "“\(name)” [\(commandID.uuidString.prefix(8))]"
        switch event {
        case .started(let pid):
            if let pid { buildPIDs[commandID] = pid }
            if isDaemon {
                states[commandID] = .daemonRunning
                DiagnosticLog.shared.log("Daemon up: \(tag)")
                notifier.post(.daemonStarted(name: name))
                resumeStep(token: token, .daemonRunning)   // a daemon step advances the chain while staying alive
                if watchdogArmed.contains(commandID) { startStabilityTask(commandID, token: token) }
            }
            startVMSamplerIfNeeded()
        case .line(let text, let stream):
            appendLog(commandID, text, stream)
            outputObserver(commandID, text, stream)
        case .terminated(let code):
            // Whether it was a live daemon before the terminal event distinguishes "dropped" vs "failed to start".
            let wasDaemonRunning = states[commandID] == .daemonRunning
            finishRun(commandID)
            flushRunPeaks(commandID, name: name)
            if stopRequested.remove(commandID) != nil {
                states[commandID] = .idle   // user stopped it — neutral, not red; silently
                DiagnosticLog.shared.log("Stopped by user: \(tag)")
                resumeStep(token: token, .cancelled)
            } else {
                states[commandID] = (code == 0) ? .succeeded : .failed(code: code)
                DiagnosticLog.shared.log("Finished: \(tag) code \(code)", level: code == 0 ? .info : .warn)
                if code != 0 { scanOOMIfNeeded(after: name, code: code) }
                if code != 0, isHostMonitoringEnabled() {
                    let tail = logs[commandID]?.elements.suffix(40).map(\.text).joined(separator: "\n") ?? ""
                    let verdict = detectOOM(exitCode: code, logTail: tail)
                    if verdict.isOOM {
                        let crate = verdict.crate.map { " · crate `\($0)`" } ?? ""
                        DiagnosticLog.shared.log("Likely OOM: \(tag) (signal 9 / SIGKILL)\(crate)", level: .warn)
                    } else if let c = verdict.crate {
                        DiagnosticLog.shared.log("Build failed at crate `\(c)`: \(tag)", level: .warn)
                    }
                }
                if isDaemon {
                    if watchdogArmed.contains(commandID) {
                        // A scheduled restart replaces the banner — no spam while the watchdog works.
                        DiagnosticLog.shared.log("Watchdog: \(tag) died (code \(code)) — scheduling restart", level: .warn)
                        scheduleWatchdogRestart(commandID)
                    } else {
                        // the daemon exited on its own, without a stop request → dropped (or failed to start)
                        notifier.post(wasDaemonRunning
                            ? .daemonStopped(name: name, code: code)
                            : .daemonFailedToStart(name: name, code: code))
                    }
                } else if code != 0 {
                    notifier.post(.commandFailed(name: name, code: code))
                }
                if isDaemon, !wasDaemonRunning, code != 0, let port = lastStarted[commandID]?.port {
                    startReactivePortCheck(commandID, port: port)
                }
                resumeStep(token: token, code == 0 ? .succeeded : .failed(code: code))
            }
        case .cancelled:
            stopRequested.remove(commandID)
            deactivateWatchdog(commandID)
            states[commandID] = .idle   // user cancellation (sudo dialog) — also neutral
            DiagnosticLog.shared.log("Cancelled by user: \(tag)")
            flushRunPeaks(commandID, name: name)
            finishRun(commandID)
            resumeStep(token: token, .cancelled)
        }
    }

    private func finishRun(_ commandID: UUID) {
        active[commandID] = nil
        consumers[commandID] = nil
    }

    private func appendLog(_ id: UUID, _ text: String, _ stream: OutputChannel) {
        logs[id, default: RingBuffer(capacity: maxLogLines)].append(LogLine(text: text, stream: stream))
    }
}
