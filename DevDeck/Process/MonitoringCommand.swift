import Foundation
import Darwin

/// A cancellation scope belongs to one UI/run probe batch, not to unrelated processes.
final class MonitoringCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let parent: MonitoringCancellation?
    init(parent: MonitoringCancellation? = nil) { self.parent = parent }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled || parent?.isCancelled == true }
}

enum MonitoringProbeWork {
    @TaskLocal static var cancellation: MonitoringCancellation?
    static func perform<T: Sendable>(_ scope: MonitoringCancellation = MonitoringCancellation(),
                                      _ body: @escaping @Sendable () -> T) async -> T {
        let childScope = MonitoringCancellation(parent: scope)
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                $cancellation.withValue(childScope) { body() }
            }.value
        } onCancel: { childScope.cancel() }
    }
}

/// Injectable process ownership boundary; unit tests use a fake child and clock.
protocol MonitoringChild: AnyObject {
    func readAvailable() -> Data
    var finishedSuccessfully: Bool? { get }
    func terminateGroupAndReap()
}

enum MonitoringCommand {
    static let timeout: TimeInterval = 5
    static func collect(_ child: any MonitoringChild, cancelled: () -> Bool,
                        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        wait: () -> Void = { Thread.sleep(forTimeInterval: 0.01) },
                        timeout: TimeInterval = timeout) -> String? {
        defer { child.terminateGroupAndReap() }
        let deadline = now() + timeout
        var output = Data()
        while !cancelled(), now() < deadline {
            output.append(child.readAvailable())
            guard output.count <= 4 * 1024 * 1024 else { return nil }
            if let success = child.finishedSuccessfully {
                while true {
                    let tail = child.readAvailable()
                    if tail.isEmpty { break }
                    output.append(tail)
                    guard output.count <= 4 * 1024 * 1024, !cancelled(), now() < deadline else { return nil }
                }
                return success ? String(data: output, encoding: .utf8) : nil
            }
            wait()
        }
        return nil
    }

    static func run(_ path: String, _ arguments: [String]) -> String? {
        let scope = MonitoringProbeWork.cancellation
        guard scope?.isCancelled != true, let child = SpawnedMonitoringChild(path, arguments) else { return nil }
        return collect(child, cancelled: { scope?.isCancelled == true })
    }
}

/// posix_spawn creates a dedicated process group atomically, before any CLI can fork.
/// Nonblocking output avoids waiting for EOF from descendants. Every exit path kills the
/// owned group and reaps the direct child. No changes to legacy ProcessTree.run callers.
private final class SpawnedMonitoringChild: MonitoringChild {
    private let pid: pid_t
    private let output: Int32
    private var status: Int32?
    init?(_ path: String, _ arguments: [String]) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ProcessTree.augmentedPATH(env["PATH"])
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let rc = argv.withUnsafeBufferPointer { av in envp.withUnsafeBufferPointer { ev in
            posix_spawn(&child, path, &actions, &attributes, av.baseAddress!, ev.baseAddress!)
        } }
        close(fds[1])
        guard rc == 0 else { close(fds[0]); return nil }
        pid = child; output = fds[0]
        _ = fcntl(output, F_SETFL, O_NONBLOCK)
    }
    func readAvailable() -> Data {
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        // Bound each drain so a continuously-writing process cannot bypass the deadline.
        for _ in 0..<32 {
            let count = read(output, &buffer, buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    var finishedSuccessfully: Bool? {
        if status == nil {
            var value: Int32 = 0
            if waitpid(pid, &value, WNOHANG) == pid { status = value }
        }
        return status.map { $0 == 0 }
    }
    func terminateGroupAndReap() {
        // Monitoring commands are read-only and have no state to flush. SIGKILL also
        // bounds cleanup when a CLI ignores TERM or a descendant holds stdout open.
        kill(-pid, SIGKILL)
        if status == nil {
            var value: Int32 = 0
            while waitpid(pid, &value, 0) == -1 && errno == EINTR {}
            status = value
        }
        close(output)
    }
}
