import Foundation
@testable import DevDeck

/// Records posted notifications — verifies orchestration without real system banners.
@MainActor
final class FakeNotifier: Notifier {
    private(set) var posted: [AppNotification] = []
    /// How many times a user-started run asked for notification permission.
    private(set) var userRunPreparations = 0
    func post(_ notification: AppNotification) { posted.append(notification) }
    func prepareForUserRun() { userRunPreparations += 1 }
}
