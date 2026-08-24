import Foundation
@testable import DevDeck

/// Scripted `docker system df` results per host — no ssh, no docker.
final class FakeDockerUsageProbe: DockerUsageProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _usage: [DockerHost: DockerUsage]
    private var _calls: [DockerHost] = []

    init(_ usage: [DockerHost: DockerUsage]) { _usage = usage }

    var calls: [DockerHost] { lock.lock(); defer { lock.unlock() }; return _calls }
    func set(_ usage: DockerUsage?, for host: DockerHost) {
        lock.lock(); defer { lock.unlock() }
        _usage[host] = usage
    }

    func sample(_ host: DockerHost) -> DockerUsage? {
        lock.lock(); defer { lock.unlock() }
        _calls.append(host)
        return _usage[host]
    }
}
