import Foundation

/// Whether editing a remote proxy's destination/SOCKS port can safely regenerate its ssh tunnel
/// command, or must leave a hand-edited command alone.
///
/// The tunnel command is a REGULAR deck command the user is free to edit directly — a jump host,
/// an identity file, `-o ServerAliveInterval=…`. The proxy editor only stores name/ports on
/// `RemoteProxy` itself; the destination lives inside that command string. So an edit made in the
/// proxy editor can only be written back to the command when the command is still EXACTLY what
/// `RemoteProxy.tunnelCommandString` would have produced for the proxy's previous values — anything
/// else means the user touched the command since, and silently overwriting that would throw the
/// edit away with no trace.
///
/// Pure — no store, no `ProxyManager`, no UI — so this decision is testable on its own.
/// `ProxyManager.applyRemoteProxyEdit(_:tunnelCommandUpdate:)` is what applies the result.
enum TunnelCommandUpdate: Equatable {
    /// Safe to persist: write this exact string as the tunnel command's new `command`.
    case rewrite(String)
    /// The stored command no longer matches what would have been generated for the proxy's
    /// PREVIOUS destination/port — the user edited it by hand. Leave it exactly as it is.
    case handEdited

    /// - Parameters:
    ///   - current: the tunnel command's `command` string as it is stored right now.
    ///   - expectedForOldValues: what `RemoteProxy.tunnelCommandString` would produce for the
    ///     proxy's PREVIOUS destination and SOCKS port — i.e. what this command held right after
    ///     it was created, or right after the last edit this same plan approved.
    ///   - newDestination: the destination typed into the edit sheet.
    ///   - newSocksPort: the SOCKS port typed into the edit sheet.
    static func plan(current: String, expectedForOldValues: String,
                      newDestination: String, newSocksPort: Int) -> TunnelCommandUpdate {
        guard current == expectedForOldValues else { return .handEdited }
        return .rewrite(RemoteProxy.tunnelCommandString(destination: newDestination, socksPort: newSocksPort))
    }
}
