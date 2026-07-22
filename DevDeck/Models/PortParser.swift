import Foundation

/// Extracts the LOCAL listening port from a daemon command string (to pre-fill `Command.port`).
/// Pure and best-effort: returns nil when the command has no unambiguous local port.
enum PortParser {

    /// Pattern priority: ssh -L → kubectl port-forward pair → --port/--listen → docker -p pair.
    static func localPort(in command: String) -> Int? {
        // ssh -L [bindaddr:]LOCAL:host:port — the group right before host:port is local.
        if let m = command.firstMatch(of: /-L\s+(?:[\w.\-\[\]]+:)?(\d{1,5}):[^\s:]+:\d+/) {
            return validated(m.1)
        }
        // kubectl port-forward … LOCAL:REMOTE. A bare ":80" (random local port) must not match.
        if let range = command.range(of: "port-forward") {
            let tail = command[range.upperBound...]
            if let m = tail.firstMatch(of: /(?:^|\s)(\d{1,5}):\d{1,5}(?:\s|$)/) {
                return validated(m.1)
            }
        }
        if let m = command.firstMatch(of: /--(?:port|listen)[=\s]+(\d{1,5})(?:\s|$)/) {
            return validated(m.1)
        }
        // docker-style publish pair only; a lone `-p N` is ambiguous (psql etc.).
        if let m = command.firstMatch(of: /-p\s+(?:[\d.]+:)?(\d{1,5}):\d{1,5}(?:\s|$)/) {
            return validated(m.1)
        }
        return nil
    }

    private static func validated(_ digits: Substring) -> Int? {
        guard let port = Int(digits), (1...65535).contains(port) else { return nil }
        return port
    }
}
