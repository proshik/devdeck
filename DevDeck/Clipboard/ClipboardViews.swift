import SwiftUI

struct ClipboardStatusView: View {
    @Environment(ClipboardModel.self) private var model
    @Environment(CommandStore.self) private var store
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.config.settings.clipboard.enabled {
                HStack {
                    Text(L10n.clipboardOff).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.clipboardEnable) { store.updateClipboard { $0.enabled = true } }
                        .controlSize(.small)
                }
            } else if model.access != .allowed {
                Text(L10n.clipboardPermission).font(compact ? .caption : .body).foregroundStyle(.secondary)
                HStack {
                    if model.access == .needsPermission {
                        Button(L10n.clipboardRequestAccess) { model.requestAccess() }.controlSize(.small)
                    }
                    Button(L10n.clipboardSystemSettings) {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                            NSWorkspace.shared.openApplication(at: url, configuration: .init())
                        }
                    }.controlSize(.small)
                }
            } else if store.config.settings.clipboard.paused {
                Text(L10n.clipboardPaused).font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                if case .writeFailed = model.error {
                    Button(L10n.clipboardRetry) { Task { await model.retry() } }.controlSize(.small)
                }
            }
        }
    }
}

struct ClipboardEntryRow: View {
    @Environment(ClipboardModel.self) private var model
    @Environment(CommandStore.self) private var store
    let entry: ClipboardEntry
    var compact = false
    var body: some View {
        HStack(spacing: 8) {
            Button { model.copy(entry) } label: {
                HStack(spacing: 8) {
                    if model.copiedID == entry.id {
                        Image(systemName: "checkmark").frame(width: 24).foregroundStyle(.secondary)
                    } else { ClipboardThumbnail(entry: entry) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayTitle).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        (Text(entry.sourceName ?? entry.sourceBundleID ?? L10n.clipboardUnknownSource)
                            + Text(" · ") + Text(entry.capturedAt, style: .time))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).controlHoverFeedback()
            .help(model.copiedID == entry.id ? L10n.clipboardCopied : L10n.clipboardCopy)
            .accessibilityLabel(L10n.clipboardCopy + ": " + String(entry.displayTitle.prefix(120)))
            ClipboardPasteButton(entry: entry)
            Button { Task { await model.setPinned(entry) } } label: {
                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(entry.isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).controlHoverFeedback().disabled(model.isBusy)
            .help(entry.isPinned ? L10n.clipboardUnpin : L10n.clipboardPin)
            .accessibilityLabel(entry.isPinned ? L10n.clipboardUnpin : L10n.clipboardPin)
        }
        .contextMenu {
            Button(L10n.clipboardCopy) { model.copy(entry) }
            if store.config.settings.clipboard.pasteEnabled {
                Button(L10n.clipboardPaste) { Task { await model.paste(entry) } }.disabled(model.isPasting)
            }
            Button(entry.isPinned ? L10n.clipboardUnpin : L10n.clipboardPin) { Task { await model.setPinned(entry) } }
            Divider()
            Button(L10n.clipboardDelete, role: .destructive) { Task { await model.remove(entry) } }
        }
    }
}

struct ClipboardSectionView: View {
    @Environment(ClipboardModel.self) private var model
    @Environment(CommandStore.self) private var store
    var onDetails: () -> Void
    @State private var query = ""
    @State private var kind: ClipboardContent.Kind?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(L10n.clipboardHistory, systemImage: "clipboard").font(.headline)
                Text("\(model.entries.count)").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if store.config.settings.clipboard.enabled {
                    Button { store.updateClipboard { $0.paused.toggle() } } label: {
                        Image(systemName: store.config.settings.clipboard.paused ? "play" : "pause")
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.borderless).controlHoverFeedback()
                        .help(store.config.settings.clipboard.paused ? L10n.clipboardResume : L10n.clipboardPause)
                        .accessibilityLabel(store.config.settings.clipboard.paused ? L10n.clipboardResume : L10n.clipboardPause)
                }
                Button(action: onDetails) {
                    Image(systemName: "arrow.up.right").frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.borderless).controlHoverFeedback().help(L10n.clipboardShowAll)
                    .accessibilityLabel(L10n.clipboardShowAll)
            }
            ClipboardStatusView(compact: true)
            if !model.entries.isEmpty {
                HStack(spacing: 8) {
                    TextField(L10n.clipboardSearch, text: $query).textFieldStyle(.roundedBorder)
                    ClipboardTypePicker(kind: $kind).controlSize(.small)
                }
                let found = model.search(query, kind: kind)
                if found.isEmpty { Text(L10n.clipboardNoMatches).foregroundStyle(.secondary).font(.caption) }
                ForEach(Array(found.prefix(6))) { entry in
                    ClipboardEntryRow(entry: entry, compact: true)
                        .padding(.vertical, 2)
                }
            } else if store.config.settings.clipboard.enabled && model.access == .allowed {
                Text(L10n.clipboardEmpty).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct ClipboardView: View {
    @Environment(ClipboardModel.self) private var model
    @Environment(CommandStore.self) private var store
    @State private var page = 0
    @State private var query = ""
    @State private var kind: ClipboardContent.Kind?
    @State private var pinnedOnly = false
    @State private var selected: UUID?
    @State private var clearRequested = false
    @State private var clearAll = false

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.clipboardTitle, selection: $page) {
                Text(L10n.clipboardHistory).tag(0)
                Text(L10n.settings).tag(1)
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 350).padding(20)
            if page == 0 { historyPage } else { settingsPage }
        }
        .navigationTitle(L10n.clipboardTitle)
        .onChange(of: query) { _, _ in clearHiddenSelection() }
        .onChange(of: kind) { _, _ in clearHiddenSelection() }
        .onChange(of: pinnedOnly) { _, _ in clearHiddenSelection() }
        .onChange(of: model.entries.map(\.id)) { _, _ in
            clearHiddenSelection()

        }
        .task { await model.synchronize(store.config.settings.clipboard) }
        .onChange(of: store.config.settings.clipboard) { _, settings in
            Task { await model.synchronize(settings) }
        }
        .alert(L10n.clipboardClearTitle, isPresented: $clearRequested) {
            Button(L10n.clipboardConfirmDelete, role: .destructive) {
                Task { await model.clear(includingPinned: clearAll) }
            }
            Button(L10n.cancel, role: .cancel) {}
        } message: { Text(clearAll ? L10n.clipboardClearAllMessage : L10n.clipboardClearMessage) }
    }
    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            ClipboardStatusView()
            HStack(spacing: 12) {
                TextField(L10n.clipboardSearch, text: $query).textFieldStyle(.roundedBorder)
                ClipboardTypePicker(kind: $kind)
                Toggle(L10n.clipboardPinnedOnly, isOn: $pinnedOnly).toggleStyle(.checkbox).fixedSize()
                Menu {
                    Button(L10n.clipboardClear) { clearAll = false; clearRequested = true }
                        .disabled(model.entries.allSatisfy(\.isPinned))
                    Button(L10n.clipboardClearAll, role: .destructive) { clearAll = true; clearRequested = true }
                } label: { Image(systemName: "trash") }
                    .disabled(model.isBusy || (model.entries.isEmpty && model.error == nil))
                    .help(L10n.clipboardClearTitle).accessibilityLabel(L10n.clipboardClearTitle)
            }
            HSplitView {
                List(selection: $selected) {
                    ForEach(model.search(query, pinnedOnly: pinnedOnly, kind: kind)) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                ClipboardThumbnail(entry: entry, size: 28)
                                if entry.isPinned { Image(systemName: "pin.fill").foregroundStyle(.tint) }
                                Text(entry.displayTitle).lineLimit(2)
                            }
                            Text(entry.sourceName ?? entry.sourceBundleID ?? L10n.clipboardUnknownSource)
                                .font(.caption).foregroundStyle(.secondary)
                            Text(entry.capturedAt, format: .dateTime.day().month().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).tag(entry.id)
                        .contextMenu {
                            Button(L10n.clipboardCopy) { model.copy(entry) }
                            if store.config.settings.clipboard.pasteEnabled {
                                Button(L10n.clipboardPaste) { Task { await model.paste(entry) } }.disabled(model.isPasting)
                            }
                            Button(entry.isPinned ? L10n.clipboardUnpin : L10n.clipboardPin) { Task { await model.setPinned(entry) } }
                            Button(L10n.clipboardDelete, role: .destructive) { Task { await model.remove(entry) } }
                        }
                    }
                }.frame(minWidth: 210, idealWidth: 280, maxWidth: 350)
                    .overlay {
                        if model.search(query, pinnedOnly: pinnedOnly, kind: kind).isEmpty {
                            Text(query.isEmpty && !pinnedOnly ? L10n.clipboardEmpty : L10n.clipboardNoMatches)
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(20)
                        }
                    }
                VStack(alignment: .leading, spacing: 12) {
                    if let entry = model.search(query, pinnedOnly: pinnedOnly, kind: kind).first(where: { $0.id == selected }) {
                        HStack {
                            Button(model.copiedID == entry.id ? L10n.clipboardCopied : L10n.clipboardCopy) { model.copy(entry) }
                            ClipboardPasteButton(entry: entry)
                            Button { Task { await model.setPinned(entry) } } label: { Image(systemName: entry.isPinned ? "pin.fill" : "pin") }
                                .help(entry.isPinned ? L10n.clipboardUnpin : L10n.clipboardPin)
                            Spacer(minLength: 4)
                            Button { Task { await model.remove(entry) } } label: { Image(systemName: "trash") }
                                .help(L10n.clipboardDelete).accessibilityLabel(L10n.clipboardDelete)
                        }.controlSize(.small).disabled(model.isBusy)
                        ClipboardContentDetail(entry: entry)
                    } else {
                        Text(L10n.clipboardSelectedText).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding(16).frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(.horizontal, 20).padding(.bottom, 20)
    }
    private func clearHiddenSelection() {
        if let selected, !model.search(query, pinnedOnly: pinnedOnly, kind: kind).contains(where: { $0.id == selected }) { self.selected = nil }
    }
    private var settingsPage: some View { ClipboardSettingsView() }
}
