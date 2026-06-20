import SwiftUI
import AppKit

/// Command editor: name/command/directory/toggles/env + a "Free memory" section.
struct CommandEditorView: View {
    @Environment(CommandStore.self) private var store
    @Environment(AppModel.self) private var appModel
    @Environment(ProcessManager.self) private var manager

    let command: Command

    @State private var draft: Command
    @State private var envRows: [EnvRow]
    @State private var runningApps: [RunningApp] = []
    @State private var confirmDelete = false
    /// Terminal launch mode — shared across all commands (a toggle for experiments).
    @AppStorage("terminalLaunchMode") private var terminalMode = TerminalLaunchMode.window.rawValue

    private let appController = LiveAppController()

    init(command: Command) {
        self.command = command
        _draft = State(initialValue: command)
        _envRows = State(initialValue: command.env
            .sorted { $0.key < $1.key }
            .map { EnvRow(key: $0.key, value: $0.value) })
    }

    var body: some View {
        Form {
            Section(L10n.commandSection) {
                TextField(L10n.name, text: $draft.name)
                TextField(L10n.commandFieldLabel, text: $draft.command, axis: .vertical).lineLimit(1...8)
                HStack {
                    TextField(L10n.workingDirectory, text: Binding(
                        get: { draft.workingDirectory ?? "" },
                        set: { draft.workingDirectory = $0.isEmpty ? nil : $0 }
                    ))
                    Button(L10n.choose) { chooseDirectory() }
                }
                Toggle(L10n.daemonToggle, isOn: $draft.isDaemon)
                Toggle(L10n.needsSudoToggle, isOn: $draft.needsSudo)
                Toggle(L10n.openInTerminalToggle, isOn: $draft.openInTerminal)
                if draft.openInTerminal {
                    Picker(L10n.terminalModePicker, selection: $terminalMode) {
                        Text(L10n.terminalWindow).tag(TerminalLaunchMode.window.rawValue)
                        Text(L10n.terminalTab).tag(TerminalLaunchMode.tab.rawValue)
                    }
                }
                if draft.command.contains("cargo") || draft.command.contains("dev-build") {
                    let cfg = effectiveVMConfig(manager.vmBuildConfig)
                    let advice = adviseJobs(command: draft.command, env: assembledDraft.env,
                                            vmCpus: cfg.cpus, limitBytes: cfg.limitBytes)
                    Text(L10n.jobsAdvice(advice.effectiveJobs, advice.advisedJobs))
                        .font(.caption)
                        .foregroundStyle(advice.overBudget ? .orange : .secondary)
                        .task { manager.refreshVMBuildConfig() }
                }
            }

            Section(L10n.envSection) {
                ForEach($envRows) { $row in
                    HStack {
                        TextField(L10n.envKeyPlaceholder, text: $row.key)
                        TextField(L10n.envValuePlaceholder, text: $row.value)
                        Button(role: .destructive) { envRows.removeAll { $0.id == row.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button(L10n.addEnvVar) { envRows.append(EnvRow(key: "", value: "")) }
            }

            Section(L10n.freeMemorySection) {
                if displayApps.isEmpty {
                    Text(L10n.noRunningApps).foregroundStyle(.secondary)
                }
                ForEach(displayApps) { app in
                    Toggle(isOn: binding(for: app)) {
                        HStack {
                            Text(app.name)
                            if !app.running { Text(L10n.notRunning).foregroundStyle(.secondary).font(.caption) }
                            Spacer()
                            if let bytes = app.memoryBytes {
                                Text(Self.formatMemory(bytes)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
                Button(L10n.refreshAppList) { refreshApps() }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshApps() }
        // Launching happens from the popover/list; the editor only has explicit "Delete" (with
        // confirmation) and "Save" (enabled only when there are unsaved changes).
        .toolbar {
            ToolbarItemGroup {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(L10n.delete, systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.red)
                }
                .help(L10n.deleteCommandHelp)

                Button { save() } label: {
                    Label(hasChanges ? L10n.save : L10n.saved, systemImage: hasChanges ? "checkmark.circle.fill" : "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges)
                .keyboardShortcut("s")
                .help(L10n.saveHelp)
            }
        }
        .confirmationDialog(L10n.deleteCommandTitle(command.name), isPresented: $confirmDelete) {
            Button(L10n.delete, role: .destructive) {
                store.delete(commandID: command.id)
                appModel.selection = nil
            }
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(L10n.deleteCommandMessage)
        }
    }

    /// Draft with the env rows assembled — what goes to the store on save.
    private var assembledDraft: Command {
        var result = draft
        result.env = Dictionary(
            envRows.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        return result
    }

    private var hasChanges: Bool { assembledDraft != command }

    // MARK: memory — displayed list

    private struct AppItem: Identifiable {
        let bundleID: String
        let name: String
        let memoryBytes: UInt64?
        let running: Bool
        var id: String { bundleID }
    }

    private var displayApps: [AppItem] {
        var items = runningApps.map {
            AppItem(bundleID: $0.bundleID, name: $0.name, memoryBytes: $0.memoryBytes, running: true)
        }
        let runningIDs = Set(runningApps.map(\.bundleID))
        for ref in draft.appsToQuit where !runningIDs.contains(ref.bundleID) {
            items.append(AppItem(bundleID: ref.bundleID, name: ref.name, memoryBytes: nil, running: false))
        }
        return items
    }

    private func binding(for app: AppItem) -> Binding<Bool> {
        Binding(
            get: { draft.appsToQuit.contains { $0.bundleID == app.bundleID } },
            set: { isOn in
                if isOn {
                    if !draft.appsToQuit.contains(where: { $0.bundleID == app.bundleID }) {
                        draft.appsToQuit.append(AppRef(bundleID: app.bundleID, name: app.name))
                    }
                } else {
                    draft.appsToQuit.removeAll { $0.bundleID == app.bundleID }
                }
            }
        )
    }

    // MARK: actions

    private func save() {
        store.upsert(assembledDraft)
    }

    private func refreshApps() {
        runningApps = appController.runningApps()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.workingDirectory = url.path
        }
    }

    private static func formatMemory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

struct EnvRow: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}
