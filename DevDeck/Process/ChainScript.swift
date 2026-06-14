import Foundation

/// Builds ONE shell script from a chain — to run the whole thing in a single terminal tab.
/// Each step: a header marker `━━ [i/n] name ━━` + its own `cd`/`env`/`sudo` + the command.
/// `stopOnError` → steps joined with `&&` (stop on the first failure), otherwise with `;`.
/// Daemon steps run in the background (`&`) so the chain doesn't hang and reaches the end.
enum ChainScript {
    static func build(_ chain: Chain, commands: [UUID: Command]) -> String {
        let total = chain.commandIDs.count
        var groups: [String] = []
        for (index, id) in chain.commandIDs.enumerated() {
            let title = "%F{6}━━ [\(index + 1)/\(total)] " + sanitize(commands[id]?.name ?? "?") + " ━━%f"
            let marker = "print -P \(doubleQuoted(title))"
            guard let cmd = commands[id] else {
                groups.append("{ \(marker); print -P \(doubleQuoted("%F{1}\(L10n.noCommandMarker)%f")); false }")
                continue
            }
            var inner: [String] = []
            if let wd = cmd.workingDirectory, !wd.isEmpty { inner.append("cd \(shQuoted(wd))") }
            for (key, value) in cmd.env.sorted(by: { $0.key < $1.key }) {
                inner.append("export \(key)=\(shQuoted(value))")
            }
            inner.append(cmd.needsSudo ? "sudo \(cmd.command)" : cmd.command)
            let sub = "( " + inner.joined(separator: "; ") + " )"
            let run = cmd.isDaemon ? "\(sub) &" : sub   // daemon → background, so the chain keeps going
            groups.append("{ \(marker); \(run) }")
        }
        return groups.joined(separator: chain.stopOnError ? " && " : " ; ")
    }

    /// A double-quoted string for `print -P`: escape `\` and `"` (but keep the `%` color codes).
    private static func doubleQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Step name in the marker: escape `%` (`print -P` expands it), plus `\` and `"`.
    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func shQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
