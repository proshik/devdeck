import XCTest
@testable import DevDeck

/// Mapping of run state to a dashboard indicator — pure logic, no SwiftUI.
final class StatusIndicatorTests: XCTestCase {

    func testCommandStates() {
        XCTAssertEqual(StatusIndicator.forCommand(nil), DeckIndicator(status: .idle, isStop: false))
        XCTAssertEqual(StatusIndicator.forCommand(.idle), DeckIndicator(status: .idle, isStop: false))
        XCTAssertEqual(StatusIndicator.forCommand(.running), DeckIndicator(status: .running, isStop: true))
        XCTAssertEqual(StatusIndicator.forCommand(.daemonRunning), DeckIndicator(status: .daemon, isStop: true))
        XCTAssertEqual(StatusIndicator.forCommand(.succeeded), DeckIndicator(status: .idle, isStop: false))
        XCTAssertEqual(StatusIndicator.forCommand(.failed(code: 1)), DeckIndicator(status: .failed, isStop: false))
    }

    func testChainStates() {
        XCTAssertEqual(StatusIndicator.forChain(nil), DeckIndicator(status: .idle, isStop: false))
        XCTAssertEqual(StatusIndicator.forChain(.idle), DeckIndicator(status: .idle, isStop: false))
        XCTAssertEqual(StatusIndicator.forChain(.running(currentIndex: 0)), DeckIndicator(status: .running, isStop: true))
        XCTAssertEqual(StatusIndicator.forChain(.succeeded), DeckIndicator(status: .idle, isStop: false))
        XCTAssertEqual(StatusIndicator.forChain(.failed(atIndex: 1, code: 2)), DeckIndicator(status: .failed, isStop: false))
        XCTAssertEqual(StatusIndicator.forChain(.stopped), DeckIndicator(status: .idle, isStop: false))
    }
}
