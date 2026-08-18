import Foundation
import Network

/// CommandRunner for the marker command `devdeck:proxy-listen -C <path>` — the built-in share
/// engine. The "process" is an in-process `BuiltInProxyListener`; the stream contract is
/// identical to a spawned gost, which is the whole point: `ProcessManager` supervises both
/// without knowing which engine is behind the daemon.
struct BuiltInProxyRunner: CommandRunner {
    func start(_ command: Command) -> any RunningProcess {
        BuiltInProxyProcess(command: command)
    }
}

/// One run of the built-in listener. `@unchecked Sendable`: mutable state is a once-flag under a
/// lock; everything else is confined to the listener's own serial queue.
final class BuiltInProxyProcess: RunningProcess, @unchecked Sendable {
    let token = UUID()
    let output: AsyncStream<RunnerOutput>

    private let continuation: AsyncStream<RunnerOutput>.Continuation
    private let lock = NSLock()
    private var listener: BuiltInProxyListener?
    private var finished = false

    init(command: Command) {
        (output, continuation) = AsyncStream.makeStream(of: RunnerOutput.self, bufferingPolicy: .unbounded)
        let configPath = String(command.command.dropFirst(ProxyShare.builtInCommandPrefix.count))
        guard let data = FileManager.default.contents(atPath: configPath),
              let spec = parseBuiltInProxyConfig(data) else {
            // Same fail-loud shape as `gost -C` on a missing/broken file: the watchdog and the
            // occupied-port machinery upstream see an ordinary daemon that died at birth.
            continuation.yield(.started(pid: nil))
            continuation.yield(.line("built-in proxy: cannot read config at \(configPath)", stream: .stderr))
            finishOnce(.terminated(exitCode: 1))
            return
        }
        // The bridge's config names a SOCKS upstream; a present-but-unparsable value is a broken
        // config, not "dial directly" — falling back silently would leak traffic past the tunnel.
        var upstream: NWEndpoint?
        if let socks = spec.upstreamSocks {
            guard let endpoint = Self.hostPortEndpoint(socks) else {
                continuation.yield(.started(pid: nil))
                continuation.yield(.line("built-in proxy: bad upstreamSocks \"\(socks)\" in \(configPath)",
                                         stream: .stderr))
                finishOnce(.terminated(exitCode: 1))
                return
            }
            upstream = endpoint
        }
        let listener = BuiltInProxyListener(port: UInt16(clamping: spec.port), auth: spec.auth,
                                            upstream: upstream) { [weak self] event in
            guard let self else { return }
            if case .terminated = event {
                self.finishOnce(event)
            } else {
                self.continuation.yield(event)
            }
        }
        self.listener = listener
        listener.start()
    }

    func stop() {
        lock.lock(); let listener = self.listener; lock.unlock()
        listener?.stop()   // its terminal event arrives through the emit closure above
    }

    /// "host:port" → an endpoint (the same last-colon split the rest of the proxy code uses).
    private static func hostPortEndpoint(_ value: String) -> NWEndpoint? {
        guard let colon = value.lastIndex(of: ":"),
              let raw = UInt16(value[value.index(after: colon)...]), raw > 0,
              let port = NWEndpoint.Port(rawValue: raw) else { return nil }
        let host = String(value[value.startIndex..<colon])
        guard !host.isEmpty else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }

    /// Exactly one terminal + finish, no matter how many paths race to it.
    private func finishOnce(_ terminal: RunnerOutput) {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        guard first else { return }
        continuation.yield(terminal)
        continuation.finish()
    }
}
