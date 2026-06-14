import XCTest
@testable import DevDeck

/// Parser for `kubectl get pods -A -o json` output → OOMKilled events.
final class OOMInspectorTests: XCTestCase {
    func testParseFindsOOMKilledLastState() {
        let json = """
        {"items":[
          {"metadata":{"namespace":"apps","name":"web-0"},
           "status":{"containerStatuses":[
             {"name":"web","restartCount":16,
              "lastState":{"terminated":{"reason":"OOMKilled","exitCode":137,
                           "finishedAt":"2026-06-11T09:00:00Z"}}}]}},
          {"metadata":{"namespace":"kube-system","name":"coredns-1"},
           "status":{"containerStatuses":[
             {"name":"coredns","restartCount":0,"lastState":{}}]}},
          {"metadata":{"namespace":"apps","name":"api-2"},
           "status":{"containerStatuses":[
             {"name":"api","restartCount":3,
              "lastState":{"terminated":{"reason":"Error","exitCode":1}}}]}}
        ]}
        """
        let events = OOMEvent.parseOOMKilled(json)
        XCTAssertEqual(events, [OOMEvent(namespace: "apps", pod: "web-0",
                                         container: "web", restartCount: 16,
                                         finishedAt: "2026-06-11T09:00:00Z")])
    }

    func testParseEmptyAndGarbage() {
        XCTAssertEqual(OOMEvent.parseOOMKilled("{\"items\":[]}"), [])
        XCTAssertEqual(OOMEvent.parseOOMKilled("not json"), [])
        XCTAssertEqual(OOMEvent.parseOOMKilled(""), [])
    }
}
