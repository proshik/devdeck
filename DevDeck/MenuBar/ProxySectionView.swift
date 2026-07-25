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

    private var shareEnabled: Bool { store.config.settings.proxyShareEnabled }
    private var discoveryEnabled: Bool { store.config.settings.proxyDiscoveryEnabled }

    var body: some View {
        if shareEnabled || discoveryEnabled {
            CollapsibleSection(title: title, count: rowCount,
                               runningCount: runningCount, collapsed: $collapsed) {
                if shareEnabled { shareRows }
                if discoveryEnabled { discoveryRows }
            }
        }
    }

    /// While consuming, name the active proxy in the header so it's readable without expanding.
    private var title: String {
        guard discoveryEnabled else { return L10n.proxy }
        return "\(L10n.proxy) · \(proxy.activeProxy?.name ?? L10n.proxyNone)"
    }

    private var rowCount: Int {
        (shareEnabled ? 1 : 0) + (discoveryEnabled ? proxy.visibleProxies.count : 0)
    }

    /// Green counter when this deck is actively sharing or has a live active proxy.
    private var runningCount: Int {
        (proxy.isAdvertising ? 1 : 0) + (proxy.activeProxy != nil ? 1 : 0)
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
                Text(found.exitIP ?? L10n.proxyEndpoint(found.host, found.port))
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
