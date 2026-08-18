import SwiftUI

/// Popover block for the Proxy Manager — deliberately minimal, matching the rest of the deck:
/// the host row behaves exactly like a daemon row (status dot, play/stop, port-conflict panel),
/// and the client list is a plain radio selection of what Bonjour found.
///
/// Only rendered for the side that is switched on, so a machine that shares sees the share row,
/// a machine that consumes sees the list, and a machine doing neither sees nothing.
struct ProxySectionView: View {
    @Environment(CommandStore.self) private var store
    @Environment(ProcessManager.self) private var manager
    @Environment(ProxyManager.self) private var proxy
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    @AppStorage("popover.section.proxy.collapsed") private var collapsed = false
    /// Flips on for a moment when the browser button finds no Chrome — inline, since a popover
    /// has no room for an alert.
    @State private var browserMissingChrome = false

    private var shareEnabled: Bool { store.config.settings.proxyShareEnabled }
    private var discoveryEnabled: Bool { store.config.settings.proxyDiscoveryEnabled }
    private var hasRemoteProxies: Bool { !store.config.remoteProxies.isEmpty }

    var body: some View {
        if shareEnabled || discoveryEnabled || hasRemoteProxies {
            CollapsibleSection(title: title, count: rowCount,
                               runningCount: runningCount, collapsed: $collapsed) {
                if shareEnabled { shareRows }
                if discoveryEnabled { discoveryRows }
                if hasRemoteProxies { remoteRows }
                if proxy.canOpenProxyBrowser { browserRow }
            }
        }
    }

    /// While consuming, name the active proxy in the header so it's readable without expanding.
    private var title: String {
        guard discoveryEnabled || hasRemoteProxies else { return L10n.proxy }
        return "\(L10n.proxy) · \(proxy.activeProxy?.name ?? L10n.proxyNone)"
    }

    private var rowCount: Int {
        (shareEnabled ? 1 : 0)
            + (discoveryEnabled ? proxy.visibleProxies.count : 0)
            + store.config.remoteProxies.count
    }

    /// Green counter when this deck is actively sharing or has a LIVE active proxy — a
    /// remembered-but-not-announced proxy is dimmed in the list, so it must not count here either.
    private var runningCount: Int {
        (proxy.isAdvertising ? 1 : 0) + (proxy.activeProxy?.isLive == true ? 1 : 0)
    }

    // MARK: host side

    @ViewBuilder
    private var shareRows: some View {
        DeckRow(
            name: L10n.proxyShareDaemonName,
            needsSudo: false,
            indicator: StatusIndicator.forCommand(proxy.shareState),
            onToggle: { toggleShare() },
            onLogs: { openProxyPage() }
        )
        if proxy.gostMissing {
            proxyNote(L10n.gostNotFound, icon: "exclamationmark.triangle.fill", color: .orange)
        } else if proxy.isAdvertising {
            HStack(spacing: 5) {
                Image(systemName: "wifi").font(.system(size: 9))
                Text(L10n.proxyAdvertising)
                if let exitIP = proxy.lastExitIP {
                    Text("·")
                    Text(exitIP).monospacedDigit()
                }
                // The popover stays a control deck: one segment on a line that already exists,
                // never a list. The full roster lives on the Proxy page.
                if proxy.connectedClientCount > 0 {
                    Text("·")
                    Text(L10n.proxyConnectedCount(proxy.connectedClientCount))
                }
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.leading, 34)
            .padding(.trailing, 16)
            .padding(.bottom, 2)
        }
        // The synthetic gost daemon has a `port`, so the existing conflict panel just works.
        if let conflict = manager.portConflicts[ProxyShare.daemonID] {
            PortConflictPanel(conflict: conflict,
                              onKill: { manager.killOccupantAndStart(ProxyShare.daemonID) },
                              onDismiss: { manager.dismissPortConflict(ProxyShare.daemonID) })
        }
    }

    // MARK: client side

    @ViewBuilder
    private var discoveryRows: some View {
        if proxy.visibleProxies.isEmpty {
            proxyNote(L10n.proxyNoneFound, icon: "antenna.radiowaves.left.and.right", color: .secondary)
        } else {
            ForEach(proxy.visibleProxies) { found in
                discoveredRow(found)
                if !found.isLive {
                    proxyNote(L10n.proxyLastKnownAddress, icon: "clock.arrow.circlepath", color: .secondary)
                }
                // The check lives under the ACTIVE proxy only — it probes what routing would use,
                // and for a locked peer without credentials the orange lock is already the message.
                if proxy.activeProxy?.name == found.name && !proxy.activeProxyNeedsCredentials {
                    checkRow
                }
            }
        }
    }

    /// One discovered proxy: radio button (active choice) · name · lock when auth is needed · exit IP.
    private func discoveredRow(_ found: DiscoveredProxy) -> some View {
        let isActive = proxy.activeProxy?.name == found.name
        return Button {
            proxy.setActiveProxy(isActive ? nil : found)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isActive ? (found.isLive ? Color.accentColor : Color.secondary)
                                              : Color.secondary)
                    .frame(width: 14)
                Text(found.name).lineLimit(1).truncationMode(.tail)
                if found.authRequired {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(proxy.activeProxyNeedsCredentials && isActive
                                         ? Color.orange : Color.secondary.opacity(0.5))
                }
                Spacer(minLength: 6)
                Text(endpointLabel(found))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.system(size: 13))
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Both addresses at once: where to dial, and — once the host reported it — where traffic
    /// exits. Showing only the exit IP hid the one address a manual `curl -x` actually needs.
    private func endpointLabel(_ found: DiscoveredProxy) -> String {
        let endpoint = L10n.proxyEndpoint(found.host, found.port)
        guard let exitIP = found.exitIP else { return endpoint }
        return "\(endpoint) → \(exitIP)"
    }

    /// The in-app equivalent of `curl -x http://host:port https://api.ipify.org`, run from THIS
    /// machine through the active proxy. The whole line is the button, so a failed or stale
    /// verdict is re-checked by clicking it again.
    private var checkRow: some View {
        Button {
            proxy.checkActiveProxy()
        } label: {
            HStack(spacing: 5) {
                switch proxy.clientCheck {
                case .idle:
                    Image(systemName: "checkmark.shield").font(.system(size: 9))
                    Text(L10n.proxyCheck)
                case .running:
                    ProgressView().controlSize(.mini)
                    Text(L10n.proxyChecking)
                case .success(let ip):
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 9))
                        .foregroundStyle(.green)
                    Text(ip).monospacedDigit()
                case .failed:
                    Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                        .foregroundStyle(.red)
                    Text(L10n.proxyCheckFailed)
                }
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(proxy.clientCheck == .running)
        .padding(.leading, 34)
        .padding(.trailing, 16)
        .padding(.bottom, 2)
    }

    // MARK: remote proxies (SSH)

    @ViewBuilder
    private var remoteRows: some View {
        ForEach(store.config.remoteProxies) { remote in
            remoteRow(remote)
            if proxy.activeRemoteProxy?.id == remote.id {
                checkRow
            }
        }
    }

    private func remoteRow(_ remote: RemoteProxy) -> some View {
        let isActive = proxy.activeRemoteProxy?.id == remote.id
        let live = isActive && proxy.activeProxy?.isLive == true
        return Button {
            proxy.setActiveRemoteProxy(isActive ? nil : remote)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isActive ? (live ? Color.accentColor : Color.secondary)
                                              : Color.secondary)
                    .frame(width: 14)
                Text(remote.name).lineLimit(1).truncationMode(.tail)
                Image(systemName: "network").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text("127.0.0.1:\(String(remote.localPort))")
                    .font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.system(size: 13))
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: browser via proxy

    /// The same launch the Proxy page offers, one tap from the tray — the browser half of an OAuth
    /// login (`/login`). Shown only when a proxy actually resolves, so the tap always has a target.
    @ViewBuilder
    private var browserRow: some View {
        Button {
            browserMissingChrome = !proxy.openProxyBrowser()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe").font(.system(size: 9))
                Text(L10n.proxyBrowserButton)
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 34)
        .padding(.trailing, 16)
        .padding(.bottom, 2)
        if browserMissingChrome {
            proxyNote(L10n.proxyBrowserChromeMissing, icon: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    // MARK: shared bits

    private func proxyNote(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).lineLimit(2)
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(color)
        .padding(.leading, 34)
        .padding(.trailing, 16)
        .padding(.bottom, 2)
    }

    private func toggleShare() {
        if StatusIndicator.forCommand(proxy.shareState).isStop {
            proxy.stopShare()
        } else {
            proxy.startShare()
        }
    }

    /// The ☰ button opens the main window on the Proxy page (there is no per-run log to show —
    /// gost's output lands in the daemon log under its own id).
    private func openProxyPage() {
        appModel.selection = .proxy
        openWindow(id: "main")
        NSApp.activate()
    }
}
