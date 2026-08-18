import AppKit

/// The proxied-browser launch: a SEPARATE Chrome instance whose traffic egresses through the
/// active proxy. Exists for the browser half of OAuth logins (Claude Code's `/login`): the page
/// must be loaded through the proxy, while the callback to `localhost` must stay direct.
///
/// The system default browser is never touched — its settings, profile and sessions are not
/// ours to change. This instance gets its own persistent profile under Application Support, so
/// the claude.ai session survives relaunches.

/// Pure: the argument vector for the proxied Chrome instance.
func proxyBrowserArguments(proxyURL: String, profileDir: String) -> [String] {
    [
        "--proxy-server=\(proxyURL)",
        // The OAuth callback lands on localhost — it must bypass the proxy or it would be
        // dialled on the REMOTE side's loopback.
        "--proxy-bypass-list=localhost;127.0.0.1",
        "--user-data-dir=\(profileDir)",
    ]
}

/// The instance's own profile — separate from any real Chrome profile by construction.
let proxyBrowserProfileURL = PrivateFile.applicationSupportDirectory
    .appendingPathComponent("ProxyBrowser")

let proxyBrowserChromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")

/// Launch the instance. False when Chrome isn't installed — the UI explains, no fallback
/// browsers in v1 (a real Chrome is the point: OAuth providers block embedded views, and
/// SSO/passkeys work only in a real browser).
@MainActor
func launchProxyBrowser(arguments: [String]) -> Bool {
    guard FileManager.default.fileExists(atPath: proxyBrowserChromeURL.path) else {
        DiagnosticLog.shared.log("Proxy browser: Google Chrome not found at \(proxyBrowserChromeURL.path)",
                                 level: .warn)
        return false
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.arguments = arguments
    NSWorkspace.shared.openApplication(at: proxyBrowserChromeURL, configuration: configuration) { _, error in
        if let error {
            DiagnosticLog.shared.log("Proxy browser: launch failed — \(error.localizedDescription)",
                                     level: .error)
        }
    }
    return true
}
