import Foundation
@testable import DevDeck

/// Keeps the change callback so a test can fire it; registers nothing with IOKit.
@MainActor
final class FakePowerSourceObserver: PowerSourceObserving {
    private(set) var onChange: (@MainActor () -> Void)?
    func start(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
}
