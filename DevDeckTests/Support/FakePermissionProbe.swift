import Foundation
@testable import DevDeck

/// Answers permission states from a table and records requests and settings links —
/// the permissions page is tested without TCC, Apple events or System Settings.
@MainActor
final class FakePermissionProbe: PermissionProbing {
    var states: [PermissionKind: PermissionState] = [:]
    /// State a request moves the permission to (the user's answer to the system prompt).
    var answers: [PermissionKind: PermissionState] = [:]
    private(set) var requested: [PermissionKind] = []
    private(set) var opened: [PermissionKind] = []

    func state(of kind: PermissionKind) async -> PermissionState { states[kind] ?? .unknown }
    func request(_ kind: PermissionKind) async {
        requested.append(kind)
        if let answer = answers[kind] { states[kind] = answer }
    }
    func openSettings(_ kind: PermissionKind) { opened.append(kind) }
}
