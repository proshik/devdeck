import XCTest
@testable import DevDeck

/// Collects all run events until the stream completes, with a timeout safety net.
func collectEvents(_ handle: any RunningProcess, timeout: TimeInterval = 15) async -> [RunnerOutput] {
    await withTaskGroup(of: [RunnerOutput]?.self) { group in
        group.addTask {
            var events: [RunnerOutput] = []
            for await event in handle.output { events.append(event) }
            return events
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? []
        group.cancelAll()
        return first ?? []
    }
}

/// Extracts lines from the specified output channel in arrival order.
func lines(_ events: [RunnerOutput], _ channel: OutputChannel) -> [String] {
    events.compactMap {
        if case .line(let text, let stream) = $0, stream == channel { return text }
        return nil
    }
}

/// Spins the main actor until the condition becomes true or the yield limit is reached.
/// The `ProcessManager` stream consumer runs on the same main executor, so
/// a few `Task.yield()` calls are enough for it to drain buffered events —
/// deterministically, without sleeps or real wall-clock time.
@MainActor
func yieldUntil(
    _ condition: () -> Bool,
    maxYields: Int = 10_000,
    message: String = "condition was not met",
    file: StaticString = #file,
    line: UInt = #line
) async {
    var n = 0
    while !condition() {
        if n >= maxYields {
            XCTFail("\(message) after \(maxYields) yields", file: file, line: line)
            return
        }
        await Task.yield()
        n += 1
    }
}

/// Wall-clock wait for a condition — for code paths that run through a BACKGROUND executor
/// (`Task.detached`): yielding the main actor does not guarantee it CPU time under load from
/// a concurrent run, so we wait with real time and a deadline.
@MainActor
func sleepUntil(
    _ condition: () -> Bool,
    timeout: TimeInterval = 5,
    message: String = "condition was not met",
    file: StaticString = #file,
    line: UInt = #line
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("\(message) after \(timeout) s", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
