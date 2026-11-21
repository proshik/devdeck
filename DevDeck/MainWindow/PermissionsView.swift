import SwiftUI
import AppKit

/// Central permissions page (REC-01): the actual state of each permission DevDeck uses, the
/// features behind it and the way to System Settings. A prompt is offered only when a feature that
/// needs the permission is on.
struct PermissionsView: View {
    let model: PermissionsModel
    var refreshOnAppear = true

    var body: some View {
        Form {
            Section {
                EmptyView()
            } footer: {
                FormFooter(L10n.permissionsIntro)
            }
            ForEach(model.rows) { row in
                Section {
                    LabeledContent(L10n.permissionStatus) {
                        Label(L10n.permissionState(row.state), systemImage: Self.symbol(row.state))
                            .foregroundStyle(Self.tint(row.state))
                    }
                    FormActionRow {
                        if row.canRequest {
                            Button(L10n.permissionRequest) { Task { await model.request(row.kind) } }
                        }
                        Button(L10n.permissionOpenSettings) { model.openSettings(row.kind) }
                    }
                } header: {
                    Text(L10n.permissionTitle(row.kind))
                } footer: {
                    FormFooter(Self.footer(row))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.permissionsTitle)
        .task { if refreshOnAppear { await model.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    static func footer(_ row: PermissionRow) -> String {
        let list = row.features.map {
            "\(L10n.permissionFeature($0.feature)) (\($0.isEnabled ? L10n.permissionFeatureOn : L10n.permissionFeatureOff))"
        }.joined(separator: ", ")
        return [L10n.permissionUsedBy(list), L10n.permissionNote(row.kind)].compactMap { $0 }.joined(separator: " ")
    }

    static func symbol(_ state: PermissionState) -> String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .denied, .missing: "xmark.circle.fill"
        case .needsApproval, .askEachTime, .notDetermined: "exclamationmark.circle"
        case .off, .unknown: "questionmark.circle"
        }
    }

    static func tint(_ state: PermissionState) -> Color {
        switch state {
        case .granted: .green
        case .denied, .missing: .red
        case .needsApproval, .askEachTime, .notDetermined: .orange
        case .off, .unknown: .secondary
        }
    }
}
