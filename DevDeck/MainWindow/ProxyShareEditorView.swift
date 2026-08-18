import SwiftUI
import AppKit

/// Proxy Manager page: the host side (share this Mac's VPN egress) above the client side
/// (pick a proxy found on the network). Both halves are independent — a Mac normally uses one.
struct ProxyShareEditorView: View {
    @Environment(CommandStore.self) private var store
    @Environment(ProxyManager.self) private var proxy

    /// Draft of the host-side config; saved explicitly so a half-typed port never restarts gost.
    @State private var draft: ProxyShare
    @State private var sharePassword = ""
    /// What is currently in the Keychain, read once — so `hasChanges` doesn't hit it per render.
    @State private var savedSharePassword = ""
    @State private var clientUsername = ""
    @State private var clientPassword = ""
    /// The proxy name the credential fields were loaded for — reset when the choice changes.
    @State private var loadedFor: String?
    /// Flips to true for 2s after "Copy" — feedback that the snippet is on the clipboard.
    @State private var didCopy = false
    /// The "Add remote proxy" sheet and its draft fields.
    @State private var addingRemote = false
    @State private var remoteName = ""
    @State private var remoteDestination = ""
    @State private var remoteLocalPort = 18888
    @State private var remoteSocksPort = 1080
    /// Shown when the browser launch finds no Chrome.
    @State private var browserError = false

    init(share: ProxyShare) {
        _draft = State(initialValue: share)
    }

    var body: some View {
        Form {
            shareSection
            connectedSection
            discoverySection
            remoteSection
            terminalHelperSection
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.proxySection)
        .onAppear {
            savedSharePassword = proxy.sharePassword() ?? ""
            sharePassword = savedSharePassword
            loadClientCredentials()
        }
        .onChange(of: proxy.activeProxy?.name) { _, _ in loadClientCredentials() }
        .sheet(isPresented: $addingRemote) { addRemoteSheet }
        .alert(L10n.proxyBrowserChromeMissing, isPresented: $browserError) {
            Button(L10n.cancel, role: .cancel) {}
        }
    }

    // MARK: - Remote proxies (SSH)

    @ViewBuilder
    private var remoteSection: some View {
        Section(L10n.proxyRemoteSection) {
            ForEach(store.config.remoteProxies) { remote in
                remoteRow(remote)
            }
            Button(L10n.proxyRemoteAdd) { resetRemoteDraft(); addingRemote = true }

            Divider()
            HStack {
                Button {
                    if !proxy.openProxyBrowser() { browserError = true }
                } label: {
                    Label(L10n.proxyBrowserButton, systemImage: "globe")
                }
                .disabled(!proxy.canOpenProxyBrowser)
                Spacer()
            }
            Text(L10n.proxyBrowserHint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func remoteRow(_ remote: RemoteProxy) -> some View {
        let isActive = store.config.settings.activeRemoteProxyID == remote.id
        let missing = remote.tunnelCommandID.flatMap { store.commandsByID[$0] } == nil
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                proxy.setActiveRemoteProxy(isActive ? nil : remote)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(remote.name)
                        Text("127.0.0.1:\(String(remote.localPort)) · \(L10n.proxyRemoteVia)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    if isActive { Text(L10n.proxyActive).font(.caption).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(missing)

            if missing { warning(L10n.proxyRemoteTunnelMissing) }
        }
        .contextMenu {
            Button(L10n.proxyRemoteDelete, role: .destructive) {
                proxy.deleteRemoteProxy(remote, alsoTunnelCommand: false)
            }
            Button(L10n.proxyRemoteDeleteTunnelToo, role: .destructive) {
                proxy.deleteRemoteProxy(remote, alsoTunnelCommand: true)
            }
        }
    }

    private var addRemoteSheet: some View {
        Form {
            TextField(L10n.proxyRemoteName, text: $remoteName)
            TextField(L10n.proxyRemoteDestination, text: $remoteDestination)
            Text(L10n.proxyRemoteDestinationHint).font(.caption).foregroundStyle(.secondary)
            TextField(L10n.proxyRemoteLocalPort, value: $remoteLocalPort, format: .number.grouping(.never))
            TextField(L10n.proxyRemoteSocksPort, value: $remoteSocksPort, format: .number.grouping(.never))
            HStack {
                Button(L10n.cancel) { addingRemote = false }
                Spacer()
                Button(L10n.save) {
                    proxy.addRemoteProxy(name: remoteName.trimmingCharacters(in: .whitespaces),
                                         destination: remoteDestination.trimmingCharacters(in: .whitespaces),
                                         localPort: remoteLocalPort, socksPort: remoteSocksPort)
                    addingRemote = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(remoteName.trimmingCharacters(in: .whitespaces).isEmpty
                          || remoteDestination.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .padding()
    }

    private func resetRemoteDraft() {
        remoteName = ""
        remoteDestination = ""
        remoteLocalPort = 18888
        remoteSocksPort = 1080
    }

    // MARK: - Share (host side)

    @ViewBuilder
    private var shareSection: some View {
        Section(L10n.proxyShareSection) {
            Toggle(L10n.proxyShareToggle, isOn: Binding(
                get: { store.config.settings.proxyShareEnabled },
                set: { proxy.setShareEnabled($0) }
            ))

            Picker(L10n.proxyEngine, selection: $draft.engine) {
                Text(L10n.proxyEngineBuiltIn).tag(ProxyEngine.builtIn)
                Text(L10n.proxyEngineGost).tag(ProxyEngine.gost)
            }
            .pickerStyle(.segmented)
            Text(L10n.proxyEngineHint).font(.caption).foregroundStyle(.secondary)

            TextField(L10n.proxyPort, value: $draft.port, format: .number.grouping(.never))
            Text(L10n.proxyPortHint).font(.caption).foregroundStyle(.secondary)

            TextField(L10n.proxyServiceName, text: $draft.serviceName,
                      prompt: Text(ProxyShare.defaultServiceName))

            Toggle(L10n.proxyAuthToggle, isOn: $draft.authEnabled)
            if draft.authEnabled {
                TextField(L10n.proxyUsername, text: $draft.username)
                SecureField(L10n.proxyPassword, text: $sharePassword)
            }

            HStack {
                Button(L10n.save) { saveShare() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!shareHasChanges)
                Spacer()
                shareStatus
            }

            // About the engine the user is CHOOSING, not the one that failed last.
            if draft.engine == .gost && proxy.gostMissing {
                warning(L10n.gostNotFound)
            }
            Text(L10n.proxyIsolatedNetworkHint).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Live status of the announcement (the listener's own status dot lives in the popover row).
    @ViewBuilder
    private var shareStatus: some View {
        if proxy.isAdvertising {
            HStack(spacing: 5) {
                Image(systemName: "wifi").foregroundStyle(.green)
                Text(L10n.proxyAdvertising)
                if let exitIP = proxy.lastExitIP {
                    Text("· \(L10n.proxyExitIP) \(exitIP)").monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text(L10n.proxyNotAdvertising).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var shareHasChanges: Bool {
        draft != store.config.proxy || sharePassword != savedSharePassword
    }

    private func saveShare() {
        // The password goes to the Keychain BEFORE the restart, so the new listener picks it up.
        proxy.setSharePassword(draft.authEnabled ? sharePassword : nil)
        savedSharePassword = draft.authEnabled ? sharePassword : ""
        proxy.saveShare(draft)
    }

    // MARK: - Connected machines (host side)

    /// Only meaningful while this Mac is sharing — a machine that only consumes has no clients.
    @ViewBuilder
    private var connectedSection: some View {
        if store.config.settings.proxyShareEnabled {
            Section(L10n.proxyConnectedSection) {
                if proxy.proxyClients.isEmpty {
                    Text(L10n.proxyNoConnections).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(proxy.proxyClients) { client in
                        connectedRow(client)
                    }
                }
            }
        }
    }

    private func connectedRow(_ client: ProxyClientMonitor.Client) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.displayName)
                // Only when it adds something: an unnamed machine already shows its address above.
                if client.hostname != nil {
                    Text(client.ip)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            connectedStatus(client)
        }
    }

    @ViewBuilder
    private func connectedStatus(_ client: ProxyClientMonitor.Client) -> some View {
        HStack(spacing: 5) {
            if client.isActive {
                Circle().fill(.green).frame(width: 7, height: 7)
                // Zero live sessions is normal for a machine idling between requests — say "active"
                // rather than "sessions: 0", which reads like a bug.
                Text(client.liveSessions > 0 ? L10n.proxySessions(client.liveSessions)
                                             : L10n.proxyClientActive)
            } else {
                Text(L10n.proxyLastSeen(minutesSince(client.lastSeen)))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Whole minutes since `date`. Evaluated during `body`, which is fine: the monitor republishes
    /// on its sweep, so the label refreshes without a timer of its own here.
    private func minutesSince(_ date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) / 60))
    }

    // MARK: - Discovery (client side)

    @ViewBuilder
    private var discoverySection: some View {
        Section(L10n.proxyDiscoverySection) {
            Toggle(L10n.proxyDiscoveryToggle, isOn: Binding(
                get: { store.config.settings.proxyDiscoveryEnabled },
                set: { proxy.setDiscoveryEnabled($0) }
            ))

            if !store.config.settings.proxyDiscoveryEnabled {
                Text(L10n.proxyNoActiveHint).font(.caption).foregroundStyle(.secondary)
            } else if proxy.visibleProxies.isEmpty {
                Text(L10n.proxySearching).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(proxy.visibleProxies) { found in
                    discoveredRow(found)
                }
            }

            // Credentials are only asked for once a password-protected proxy is actually chosen.
            if let active = proxy.activeProxy, active.authRequired {
                TextField(L10n.proxyUsername, text: $clientUsername)
                SecureField(L10n.proxyPassword, text: $clientPassword)
                HStack {
                    Button(L10n.save) { saveClientCredentials(for: active.name) }
                        .disabled(clientUsername.isEmpty)
                    Spacer()
                    if proxy.activeProxyNeedsCredentials {
                        warning(L10n.proxyAuthRequired)
                    }
                }
            }
        }
    }

    private func discoveredRow(_ found: DiscoveredProxy) -> some View {
        let isActive = proxy.activeProxy?.name == found.name
        return Button {
            proxy.setActiveProxy(isActive ? nil : found)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? (found.isLive ? Color.accentColor : Color.secondary)
                                              : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(found.name)
                        if found.authRequired {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(detail(for: found)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if isActive {
                    Text(L10n.proxyActive).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detail(for found: DiscoveredProxy) -> String {
        guard found.isLive else {
            return "\(L10n.proxyEndpoint(found.host, found.port)) · \(L10n.proxyLastKnownAddress)"
        }
        var parts = [L10n.proxyEndpoint(found.host, found.port), found.proto]
        if let exitIP = found.exitIP { parts.append("\(L10n.proxyExitIP) \(exitIP)") }
        return parts.joined(separator: " · ")
    }

    /// Pull the stored credentials for the current choice; clears the fields when it changes.
    private func loadClientCredentials() {
        let name = proxy.activeProxy?.name
        guard loadedFor != name else { return }
        loadedFor = name
        clientUsername = store.config.settings.activeProxyUsername ?? ""
        clientPassword = name.flatMap { proxy.clientPassword(for: $0) } ?? ""
    }

    private func saveClientCredentials(for name: String) {
        proxy.setClientCredentials(username: clientUsername,
                                   password: clientPassword.isEmpty ? nil : clientPassword,
                                   for: name)
    }

    private func warning(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text)
        }
        .font(.caption)
    }

    // MARK: - Terminal helper

    @ViewBuilder
    private var terminalHelperSection: some View {
        Section(L10n.proxyTerminalHelperSection) {
            Text(L10n.proxyTerminalHelperHint).font(.caption).foregroundStyle(.secondary)
            Text(proxyShellHelperSnippet)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(proxyEnvFileDisplayPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(didCopy ? L10n.copied : L10n.copy) { copySnippet() }
            }
            // Only when it is actually true of the current choice: an open proxy puts no secret on
            // disk, and a warning that is always on stops being read.
            if proxy.activeProxy?.authRequired == true {
                warning(L10n.proxyTerminalHelperPasswordWarning)
            }
        }
    }

    private func copySnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proxyShellHelperSnippet, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }
}
