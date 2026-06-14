import Foundation

/// Semantic status of a control panel row (color is assigned by the View).
enum DeckStatus: Equatable {
    case idle      // grey
    case running   // yellow + spinner
    case daemon    // green
    case failed    // red
}

/// What to render in the row: status dot + action (▶ or ■).
struct DeckIndicator: Equatable {
    let status: DeckStatus
    let isStop: Bool   // true → show ■ (stop), false → ▶ (start)
}

/// Pure mapping of run state to a control panel indicator — no SwiftUI, fully testable.
enum StatusIndicator {
    static func forCommand(_ state: ProcessManager.RunState?) -> DeckIndicator {
        switch state {
        case nil, .idle, .succeeded:
            return DeckIndicator(status: .idle, isStop: false)
        case .running:
            return DeckIndicator(status: .running, isStop: true)
        case .daemonRunning:
            return DeckIndicator(status: .daemon, isStop: true)
        case .failed:
            return DeckIndicator(status: .failed, isStop: false)
        }
    }

    static func forChain(_ state: ProcessManager.ChainState?) -> DeckIndicator {
        switch state {
        case nil, .idle, .succeeded, .stopped:
            return DeckIndicator(status: .idle, isStop: false)
        case .running:
            return DeckIndicator(status: .running, isStop: true)
        case .failed:
            return DeckIndicator(status: .failed, isStop: false)
        }
    }
}
