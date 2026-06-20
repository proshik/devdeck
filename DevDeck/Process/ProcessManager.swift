import Foundation
import Observation

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

    init(
        runner: any CommandRunner,
        notifier: any Notifier = NoopNotifier(),
        appController: any AppController = LiveAppController(),
        reaper: any DaemonReaper = LiveDaemonReaper(),
        maxLogLines: Int = 2000,
        appQuitTimeout: TimeInterval = 10,
        vmProbe: any VMMemoryProbing = LiveVMMemoryProbe(),
        vmMonitoringEnabled: @escaping () -> Bool = { true },
        minikubeProbe: any MinikubeProbing = LiveMinikubeProbe(),
        oomInspector: any OOMInspecting = LiveOOMInspector(),
        minikubeMonitoringEnabled: @escaping () -> Bool = { false },
        hostProbe: any HostMetricsProbing = LiveHostMetricsProbe(),
        hostMonitoringEnabled: @escaping () -> Bool = { true }
    ) {
        self.runner = runner
        self.notifier = notifier
        self.appController = appController
        self.reaper = reaper
        self.maxLogLines = maxLogLines
        self.appQuitTimeout = appQuitTimeout
        self.vmProbe = vmProbe
        self.isVMMonitoringEnabled = vmMonitoringEnabled
        self.minikubeProbe = minikubeProbe
        self.oomInspector = oomInspector
        self.isMinikubeMonitoringEnabled = minikubeMonitoringEnabled
        self.hostProbe = hostProbe
        self.isHostMonitoringEnabled = hostMonitoringEnabled
    }

    /// Prod default: the real zsh/sudo router + a live app controller.
    convenience init(maxLogLines: Int = 2000) {
        self.init(runner: RoutingCommandRunner(), maxLogLines: maxLogLines)
    }

    // MARK: commands

    /// Run a command from the UI. With a non-empty `appsToQuit` — memory freeing:
    /// gently quit the apps → run → on the terminal event (always) relaunch the closed ones.
    func run(_ command: Command) {
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
    private func startRun(_ command: Command) -> UUID? {
        // Hard rule: a sudo daemon is impossible (no stream/pid/stop).
        guard !(command.needsSudo && command.isDaemon) else {
            logs[command.id] = RingBuffer(capacity: maxLogLines)
            appendLog(command.id, L10n.sudoDaemonUnsupported, .stderr)
            states[command.id] = .failed(code: -1)
            DiagnosticLog.shared.log("Rejected: sudo daemon “\(command.name)”", level: .error)
            return nil
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

        let handle = runner.start(command)
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
            DiagnosticLog.shared.log("Adopted daemon: “\(command.name)” PID \(pid)")
            notifier.post(.daemonAdopted(name: command.name))
        }
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
            }
            startVMSamplerIfNeeded()
        case .line(let text, let stream):
            appendLog(commandID, text, stream)
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
                    // the daemon exited on its own, without a stop request → dropped (or failed to start)
                    notifier.post(wasDaemonRunning
                        ? .daemonStopped(name: name, code: code)
                        : .daemonFailedToStart(name: name, code: code))
                } else if code != 0 {
                    notifier.post(.commandFailed(name: name, code: code))
                }
                resumeStep(token: token, code == 0 ? .succeeded : .failed(code: code))
            }
        case .cancelled:
            stopRequested.remove(commandID)
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
