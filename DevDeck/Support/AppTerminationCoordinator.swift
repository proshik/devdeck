import AppKit

/// Quit decisions happen once. A deferred reply belongs to the actual collector cleanup,
/// including a test the user already cancelled, rather than to its UI progress flag.
@MainActor final class AppTerminationCoordinator {
    enum DaemonChoice { case kill, leaveBackground, cancel }
    private enum Phase { case idle, deciding, waiting, approved }
    private var phase = Phase.idle
    private var shutdown: Task<Void, Never>?
    private let network: NetworkMonitoringModel
    init(network: NetworkMonitoringModel) { self.network = network }

    func request(daemons: [UUID], choose: () -> DaemonChoice, stopDaemon: (UUID) -> Void,
                 reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        switch phase {
        case .waiting: return .terminateLater
        case .approved: return .terminateNow
        case .deciding: return .terminateCancel
        case .idle: break
        }
        phase = .deciding
        if daemons.isEmpty {
            DiagnosticLog.shared.log("Quit (no live daemons)")
        } else {
            switch choose() {
            case .cancel:
                phase = .idle
                DiagnosticLog.shared.log("Quit cancelled")
                return .terminateCancel
            case .kill:
                DiagnosticLog.shared.log("Quit: kill \(daemons.count) daemons", level: .warn)
                daemons.forEach(stopDaemon)
            case .leaveBackground:
                DiagnosticLog.shared.log("Quit: keep \(daemons.count) daemons in background")
            }
        }
        network.prepareForTermination()
        guard network.hasPendingTest else {
            phase = .approved
            return .terminateNow
        }
        phase = .waiting
        shutdown = Task {
            await network.waitForTestCleanup()
            phase = .approved
            shutdown = nil
            reply(true)
        }
        return .terminateLater
    }
}
