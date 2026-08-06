import Foundation
import Observation

/// Who is using this machine's proxy share, folded out of the listener's own log stream.
///
/// The host side had no answer to "did anyone actually connect?" — the deck showed its listener was
/// up and announced, and nothing else. `gost` already reports every session open and close on
/// stderr, and `ProcessManager` already streams that; this type is the fold from those events to a
/// per-machine list.
///
/// Read-only observation on purpose: no byte counters, no destination hosts, no way to kick a peer.
///
/// Clock and resolver are injected (the probe pattern used across the proxy subsystem), so every
/// window below is tested without waiting for it.
@MainActor
@Observable
final class ProxyClientMonitor {

    /// One machine, identified by its address. Everything a view needs is precomputed here —
    /// views never touch the clock or the windows.
    struct Client: Identifiable, Equatable {
        let ip: String
        /// Resolved reverse name with `.local` stripped; nil while unresolved or unresolvable.
        var hostname: String?
        /// Sessions open right now. Zero is normal for a machine that is merely idle between requests.
        var liveSessions: Int
        let firstSeen: Date
        var lastSeen: Date
        /// Computed at publish time — see `activeWindow`.
        var isActive: Bool = false

        var id: String { ip }
        /// What the UI labels the row with. A bare IP is a worse name, never a wrong one.
        var displayName: String { hostname ?? ip }
    }

    /// Active machines first, then by last activity. Rebuilt at most once per `publishInterval`.
    private(set) var clients: [Client] = []
    /// What the popover counts. Derived, so it can never disagree with the list.
    var activeCount: Int { clients.filter(\.isActive).count }

    @ObservationIgnored private let naming: any ProxyClientNaming
    @ObservationIgnored private let now: () -> Date
    /// A machine with no open session still counts as connected for this long. Proxy sessions are
    /// short: without this the list would blink empty between two requests and the popover counter
    /// would flap.
    @ObservationIgnored private let activeWindow: TimeInterval
    /// How long a quiet machine stays listed (dimmed) before it is swept.
    @ObservationIgnored private let retention: TimeInterval
    /// How long a failed reverse lookup is remembered before another attempt. A peer can appear a
    /// moment before its mDNS record does, so failures are retried — just not per request.
    @ObservationIgnored private let nameRetryDelay: TimeInterval
    @ObservationIgnored private let publishInterval: Duration
    @ObservationIgnored private let sweepInterval: Duration

    /// Live sessions: sid → the machine that owns it.
    @ObservationIgnored private var sessions: [String: String] = [:]
    @ObservationIgnored private var entries: [String: Client] = [:]
    /// IP → the earliest time we may ask the resolver about it again. Also the in-flight guard.
    @ObservationIgnored private var nameRetryAfter: [String: Date] = [:]
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var sweepTask: Task<Void, Never>?

    /// This machine talking to its own listener — the exit-IP probe and a local `dp`. Not a peer.
    private static let ignoredIPs: Set<String> = ["127.0.0.1", "::1"]

    init(naming: any ProxyClientNaming = ReverseDNSClientNaming(),
         now: @escaping () -> Date = { Date() },
         activeWindow: TimeInterval = 120,
         retention: TimeInterval = 600,
         nameRetryDelay: TimeInterval = 300,
         publishInterval: Duration = .milliseconds(500),
         sweepInterval: Duration = .seconds(15)) {
        self.naming = naming
        self.now = now
        self.activeWindow = activeWindow
        self.retention = retention
        self.nameRetryDelay = nameRetryDelay
        self.publishInterval = publishInterval
        self.sweepInterval = sweepInterval
    }

    // MARK: - Input

    /// Fold one line of the listener's output into the list. Lines that are not session events —
    /// the overwhelming majority — cost one failed JSON parse and nothing else.
    func ingest(_ line: String) {
        guard let event = parseGostLogLine(line) else { return }
        let stamp = now()
        switch event {
        case .sessionOpened(let client, let sid):
            guard let ip = proxyClientIP(client), !Self.ignoredIPs.contains(ip) else { return }
            sessions[sid] = ip
            var entry = entries[ip] ?? Client(ip: ip, hostname: nil, liveSessions: 0,
                                              firstSeen: stamp, lastSeen: stamp)
            entry.liveSessions += 1
            entry.lastSeen = stamp
            entries[ip] = entry
            resolveNameIfNeeded(ip, at: stamp)
        case .sessionClosed(let sid):
            // An unknown sid belongs to a listener that is already gone — ignore it rather than
            // decrementing a counter that was reset under it.
            guard let ip = sessions.removeValue(forKey: sid), var entry = entries[ip] else { return }
            entry.liveSessions = max(0, entry.liveSessions - 1)
            entry.lastSeen = stamp
            entries[ip] = entry
        }
        schedulePublish()
    }

    // MARK: - Lifecycle

    /// The listener came up. Live sessions died with the previous process; who was here does not.
    func listenerDidStart() {
        sessions.removeAll()
        // Array(): the keys view is being mutated through while it is iterated.
        for ip in Array(entries.keys) { entries[ip]?.liveSessions = 0 }
        startSweep()
        publishNow()
    }

    /// The share was switched off — nobody is connected to something that is not running.
    func clear() {
        sweepTask?.cancel(); sweepTask = nil
        publishTask?.cancel(); publishTask = nil
        sessions.removeAll()
        entries.removeAll()
        nameRetryAfter.removeAll()
        publish()
    }

    // MARK: - Names

    private func resolveNameIfNeeded(_ ip: String, at stamp: Date) {
        guard entries[ip]?.hostname == nil else { return }
        if let retryAfter = nameRetryAfter[ip], stamp < retryAfter { return }
        // Set before the await: this doubles as the in-flight guard, so a burst of sessions from one
        // unnamed peer asks the resolver once, not once per request.
        nameRetryAfter[ip] = stamp.addingTimeInterval(nameRetryDelay)
        let naming = naming
        Task { @MainActor [weak self] in
            let name = await naming.hostname(for: ip)
            guard let self, let name, !name.isEmpty else { return }
            self.entries[ip]?.hostname = name
            self.schedulePublish()
        }
    }

    // MARK: - Publishing

    /// Rebuild `clients` immediately. Called by the sweep, by lifecycle changes, and by tests.
    func publishNow() {
        publishTask?.cancel()
        publishTask = nil
        publish()
    }

    /// A busy peer produces two events per request, so hundreds a second is ordinary — that must not
    /// become hundreds of SwiftUI invalidations.
    private func schedulePublish() {
        guard publishTask == nil else { return }
        let interval = publishInterval
        publishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            self.publishTask = nil
            self.publish()
        }
    }

    private func publish() {
        let stamp = now()
        let window = activeWindow
        clients = entries.values
            .map { entry -> Client in
                var client = entry
                client.isActive = entry.liveSessions > 0
                    || stamp.timeIntervalSince(entry.lastSeen) < window
                return client
            }
            .sorted { a, b in
                if a.isActive != b.isActive { return a.isActive }
                if a.lastSeen != b.lastSeen { return a.lastSeen > b.lastSeen }
                return a.ip < b.ip
            }
    }

    // MARK: - Sweep

    /// Drop machines that have been quiet past the retention window, and republish: both the active
    /// flag and the "N min ago" label change with the passage of time alone, with no events at all.
    func sweepNow() {
        let stamp = now()
        let retention = retention
        entries = entries.filter {
            $0.value.liveSessions > 0 || stamp.timeIntervalSince($0.value.lastSeen) < retention
        }
        publishNow()
    }

    private func startSweep() {
        guard sweepTask == nil else { return }
        let interval = sweepInterval
        sweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.sweepNow()
            }
        }
    }
}
