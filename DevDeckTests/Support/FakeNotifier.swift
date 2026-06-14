import Foundation
@testable import DevDeck

/// Records posted notifications — verifies orchestration without real system banners.
@MainActor
final class FakeNotifier: Notifier {
    private(set) var posted: [AppNotification] = []
    func post(_ notification: AppNotification) { posted.append(notification) }
}
