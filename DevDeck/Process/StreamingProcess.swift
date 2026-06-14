import Foundation

/// A single run on top of `Foundation.Process` with line-by-line stdout+stderr streaming.
/// Shared machinery for zsh and sudo runners; differences are injected via closures.
///
/// `@unchecked Sendable`: mutable internal state is serialized through `lock`;
/// `Process`/`FileHandle`/accumulators are never exposed outside — only Sendable
/// `RunnerOutput` values cross the actor boundary.
///
/// Invariant: exactly one `.started` → 0..n `.line` → exactly one terminal event
/// (`.terminated`/`.cancelled`) → `finish()`. The terminal is emitted AFTER draining
/// both pipes (EOF) AND receiving the exit code — otherwise the tail of output is lost.
/// However, if a surviving grandchild holds the write end of the pipe open, EOF will
/// never arrive: in that case a grace timer fires after process exit and forces the terminal.
final class StreamingProcess: RunningProcess, @unchecked Sendable {
    let token = UUID()
    let output: AsyncStream<RunnerOutput>

    private let continuation: AsyncStream<RunnerOutput>.Continuation
    private let startedPID: (Process) -> Int32?
    private let mapTerminal: (_ code: Int32, _ cancelled: Bool) -> RunnerOutput
    private let cancelMarkers: [String]

    private let lock = NSLock()
    private var process: Process?
    private var outReadHandle: FileHandle?
    private var errReadHandle: FileHandle?
    private var carry: [OutputChannel: Data] = [.stdout: Data(), .stderr: Data()]
    private var outOpen = true
    private var errOpen = true
    private var startedEmitted = false
    private var exitCode: Int32?
    private var sawCancel = false
    private var didFinish = false
    private var stopRequested = false
    private var escalation: DispatchSourceTimer?
    private var drainTimer: DispatchSourceTimer?

    private static let maxLineBytes = 1_048_576          // guard against a line with no \n
    private static let killGrace: TimeInterval = 3.0     // SIGTERM → SIGKILL window
    private static let drainGrace: TimeInterval = 0.2    // window to flush tail after exit, then force-terminal

    init(
        makeProcess: () throws -> Process,
        startedPID: @escaping (Process) -> Int32?,
        mapTerminal: @escaping (_ code: Int32, _ cancelled: Bool) -> RunnerOutput,
        cancelMarkers: [String] = []
    ) {
        self.startedPID = startedPID
        self.mapTerminal = mapTerminal
        self.cancelMarkers = cancelMarkers
        (output, continuation) = AsyncStream.makeStream(
            of: RunnerOutput.self, bufferingPolicy: .unbounded
        )
        launch(makeProcess)
    }

    deinit {
        escalation?.cancel()
        drainTimer?.cancel()
    }

    // MARK: launch

    private func launch(_ makeProcess: () throws -> Process) {
        let process: Process
        do {
            process = try makeProcess()
        } catch {
            emitLaunchFailure(error)
            return
        }

        let outPipe = process.standardOutput as! Pipe
        let errPipe = process.standardError as! Pipe
        installReader(outPipe, channel: .stdout)
        installReader(errPipe, channel: .stderr)
        process.terminationHandler = { [weak self] proc in self?.handleTermination(proc) }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            emitLaunchFailure(error)
            return
        }

        lock.lock()
        self.process = process
        outReadHandle = outPipe.fileHandleForReading
        errReadHandle = errPipe.fileHandleForReading
        startedEmitted = true
        lock.unlock()

        continuation.yield(.started(pid: startedPID(process)))
        finishIfReady()   // in case the terminal was already ready and waiting for startedEmitted
    }

    private func emitLaunchFailure(_ error: Error) {
        lock.lock(); didFinish = true; lock.unlock()
        continuation.yield(.started(pid: nil))
        continuation.yield(.line("launch failed: \(error.localizedDescription)", stream: .stderr))
        continuation.yield(.terminated(exitCode: 127))
        continuation.finish()
    }

    // MARK: pipe reading (parallel, anti-deadlock)

    private func installReader(_ pipe: Pipe, channel: OutputChannel) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.handleEOF(channel)
            } else {
                self.handleData(chunk, channel: channel)
            }
        }
    }

    private func handleData(_ chunk: Data, channel: OutputChannel) {
        var lines: [String] = []
        lock.lock()
        carry[channel, default: Data()].append(chunk)
        while let nl = carry[channel]!.firstIndex(of: 0x0A) {
            let data = carry[channel]!
            var lineData = Data(data[data.startIndex..<nl])
            if lineData.last == 0x0D { lineData.removeLast() }      // \r\n → strip \r
            lines.append(String(decoding: lineData, as: UTF8.self))
            carry[channel] = Data(data[data.index(after: nl)...])  // remainder after \n, rebased
        }
        // Giant line with no \n: force-flush without splitting a multibyte UTF-8 sequence.
        if carry[channel]!.count > Self.maxLineBytes {
            let bytes = [UInt8](carry[channel]!)
            let n = Self.utf8SafePrefixLength(bytes)
            lines.append(String(decoding: bytes[0..<n], as: UTF8.self))
            carry[channel] = Data(bytes[n...])
        }
        if channel == .stderr {
            for line in lines where cancelMarkers.contains(where: line.contains) { sawCancel = true }
        }
        lock.unlock()
        for line in lines { continuation.yield(.line(line, stream: channel)) }
    }

    private func handleEOF(_ channel: OutputChannel) {
        let tail = flushCarryTail(channel, markClosed: true)
        if let tail { continuation.yield(.line(tail, stream: channel)) }
        finishIfReady()
    }

    /// Drain the remaining carry for a channel as a single line; if `markClosed`, mark the pipe as closed.
    private func flushCarryTail(_ channel: OutputChannel, markClosed: Bool) -> String? {
        var tail: String?
        lock.lock()
        if let data = carry[channel], !data.isEmpty {
            var lineData = data
            if lineData.last == 0x0D { lineData.removeLast() }
            tail = String(decoding: lineData, as: UTF8.self)
            carry[channel] = Data()
        }
        if channel == .stderr, let tail, cancelMarkers.contains(where: tail.contains) { sawCancel = true }
        if markClosed {
            if channel == .stdout { outOpen = false } else { errOpen = false }
        }
        lock.unlock()
        return tail
    }

    // MARK: termination (single reaping point)

    private func handleTermination(_ proc: Process) {
        let code: Int32 = (proc.terminationReason == .uncaughtSignal)
            ? 128 + proc.terminationStatus
            : proc.terminationStatus
        lock.lock()
        exitCode = code
        escalation?.cancel()
        escalation = nil
        lock.unlock()
        scheduleDrainTimeout()   // a grandchild may hold the pipe open → EOF won't arrive; force terminal after grace
        finishIfReady()
    }

    private func scheduleDrainTimeout() {
        lock.lock()
        guard !didFinish, drainTimer == nil else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + Self.drainGrace)
        timer.setEventHandler { [weak self] in self?.forceFinish() }
        drainTimer = timer
        lock.unlock()
        timer.resume()
    }

    /// Force the terminal event even if pipes have not given EOF (a surviving grandchild holds the write end).
    private func forceFinish() {
        var tails: [(String, OutputChannel)] = []
        lock.lock()
        if didFinish { lock.unlock(); return }
        for channel in [OutputChannel.stdout, .stderr] {
            if let data = carry[channel], !data.isEmpty {
                var lineData = data
                if lineData.last == 0x0D { lineData.removeLast() }
                tails.append((String(decoding: lineData, as: UTF8.self), channel))
                carry[channel] = Data()
            }
        }
        outOpen = false
        errOpen = false
        let outH = outReadHandle, errH = errReadHandle
        outReadHandle = nil
        errReadHandle = nil
        lock.unlock()
        outH?.readabilityHandler = nil
        errH?.readabilityHandler = nil
        for (line, channel) in tails { continuation.yield(.line(line, stream: channel)) }
        finishIfReady()
    }

    private func finishIfReady() {
        lock.lock()
        guard !didFinish, startedEmitted, !outOpen, !errOpen, let code = exitCode else { lock.unlock(); return }
        didFinish = true
        process = nil
        escalation?.cancel(); escalation = nil
        drainTimer?.cancel(); drainTimer = nil
        let cancelled = sawCancel
        lock.unlock()
        continuation.yield(mapTerminal(code, cancelled))
        continuation.finish()
    }

    // MARK: stop (SIGTERM → grace → SIGKILL)

    func stop() {
        lock.lock()
        guard let process, !stopRequested, !didFinish, exitCode == nil else { lock.unlock(); return }
        stopRequested = true
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + Self.killGrace)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let running = self.process
            self.escalation = nil
            self.lock.unlock()
            if let running, running.isRunning {
                kill(running.processIdentifier, SIGKILL)
            }
        }
        escalation = timer
        lock.unlock()
        timer.resume()
        process.terminate()
    }

    // MARK: UTF-8

    /// Length of the prefix that does not split a multibyte UTF-8 sequence:
    /// we drop an incomplete tail so it stays in carry until the next chunk.
    private static func utf8SafePrefixLength(_ bytes: [UInt8]) -> Int {
        var cont = 0
        var i = bytes.count
        while i > 0 {
            let b = bytes[i - 1]
            if b & 0xC0 == 0x80 {           // continuation byte
                cont += 1
                i -= 1
                if cont > 3 { return bytes.count }
                continue
            }
            let needed: Int
            if b & 0x80 == 0 { needed = 0 }
            else if b & 0xE0 == 0xC0 { needed = 1 }
            else if b & 0xF0 == 0xE0 { needed = 2 }
            else if b & 0xF8 == 0xF0 { needed = 3 }
            else { return bytes.count }     // invalid lead byte — flush everything
            return cont >= needed ? bytes.count : i - 1
        }
        return bytes.count
    }
}
