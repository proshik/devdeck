import XCTest
@testable import DevDeck

/// `DevDeck automation proxy …` and `awake …`: argument parsing into the wire request.
final class AutomationProxyAwakeParsingTests: XCTestCase {

    private func parse(_ args: [String]) -> Result<AutomationCLI.Invocation, AutomationCLI.UsageError> {
        AutomationCLI.parse(args, currentDirectory: "/Users/someone", isDevelopmentBuild: false)
    }

    private func request(_ args: [String]) -> AutomationRequest? {
        guard case .success(.request(let request, _)) = parse(args) else { return nil }
        return request
    }

    private func proxy(_ args: [String]) -> AutomationProxyRequest? { request(["proxy"] + args)?.proxy }

    private func usage(_ args: [String]) -> String? {
        guard case .failure(let error) = parse(args) else { return nil }
        return error.message
    }

    // MARK: proxy

    func testProxyReadActions() {
        XCTAssertEqual(request(["proxy", "list"]),
                       AutomationRequest(operation: .proxy, proxy: AutomationProxyRequest(action: .list)))
        XCTAssertEqual(proxy(["status"])?.action, .status)
        XCTAssertEqual(proxy(["check"])?.action, .check)
        XCTAssertEqual(proxy(["share", "status"])?.action, .shareStatus)
        XCTAssertEqual(proxy(["share", "on"])?.action, .shareOn)
        XCTAssertEqual(proxy(["share", "off"])?.action, .shareOff)
    }

    func testProxyUseTakesOneTargetWithSpaces() {
        XCTAssertEqual(proxy(["use", "Office Mac"]), AutomationProxyRequest(action: .use, target: "Office Mac"))
        XCTAssertEqual(proxy(["use", "none"])?.target, "none")
        XCTAssertNotNil(usage(["proxy", "use"]))
        XCTAssertNotNil(usage(["proxy", "use", "  "]))
        XCTAssertEqual(usage(["proxy", "use", "Office", "Mac"]),
                       L10n.automationUsage(L10n.automationUsageExtraArgument("Mac")))
        XCTAssertEqual(usage(["proxy", "use", "x", "--timeout", "5"]),
                       L10n.automationUsage(L10n.automationUsageUnknownOption("--timeout")))
    }

    func testProxyRejectsUnknownAndExtraWords() {
        XCTAssertEqual(usage(["proxy"]), L10n.automationUsage(L10n.automationUsageNoProxyAction))
        XCTAssertEqual(usage(["proxy", "add"]), L10n.automationUsage(L10n.automationUsageUnknownProxyAction("add")))
        XCTAssertNotNil(usage(["proxy", "list", "extra"]))
        XCTAssertNotNil(usage(["proxy", "check", "--display", "x"]))
        XCTAssertEqual(usage(["proxy", "share"]), L10n.automationUsage(L10n.automationUsageNoShareAction))
        XCTAssertEqual(usage(["proxy", "share", "toggle"]),
                       L10n.automationUsage(L10n.automationUsageUnknownShareAction("toggle")))
        XCTAssertNotNil(usage(["proxy", "share", "on", "now"]))
    }

    func testShareSetCollectsEveryOption() {
        XCTAssertEqual(proxy(["share", "set", "--port", "8899", "--engine", "gost", "--service-name", "Lab Mac",
                              "--auth", "on", "--username", "ann"]),
                       AutomationProxyRequest(action: .shareSet, port: 8899, engine: .gost, serviceName: "Lab Mac",
                                              auth: true, username: "ann"))
        XCTAssertEqual(proxy(["share", "set", "--auth", "off"])?.auth, false)
        XCTAssertEqual(proxy(["share", "set", "--engine", "builtin"])?.engine, .builtIn, "engine case is forgiven")
        XCTAssertEqual(proxy(["share", "set", "--service-name", ""])?.serviceName, "",
                       "an empty service name means the host name")
    }

    func testShareSetValidation() {
        XCTAssertEqual(usage(["proxy", "share", "set"]), L10n.automationUsage(L10n.automationUsageNoShareField))
        for bad in ["0", "65536", "-1", "80a", ""] {
            XCTAssertEqual(usage(["proxy", "share", "set", "--port", bad]),
                           L10n.automationUsage(L10n.automationUsageBadPort(bad)), bad)
        }
        XCTAssertEqual(usage(["proxy", "share", "set", "--engine", "socks"]),
                       L10n.automationUsage(L10n.automationUsageBadEngine("socks")))
        XCTAssertEqual(usage(["proxy", "share", "set", "--auth", "yes"]),
                       L10n.automationUsage(L10n.automationUsageBadAuth("yes")))
        XCTAssertEqual(usage(["proxy", "share", "set", "--port"]),
                       L10n.automationUsage(L10n.automationUsageMissingValue("--port")))
        XCTAssertEqual(usage(["proxy", "share", "set", "--password", "x"]),
                       L10n.automationUsage(L10n.automationUsageUnknownOption("--password")),
                       "passwords are never accepted")
        XCTAssertNotNil(usage(["proxy", "share", "set", "9999"]))
        XCTAssertEqual(usage(["proxy", "share", "set", "--password=hunter2"]),
                       L10n.automationUsage(L10n.automationUsageUnknownOption("--password")),
                       "the value of an unknown option is never echoed")
        XCTAssertFalse(usage(["run", "command", "x", "--token=hunter2"])?.contains("hunter2") ?? true)
    }

    // MARK: awake

    func testAwakeActions() {
        XCTAssertEqual(request(["awake", "on"]),
                       AutomationRequest(operation: .awake, awake: AutomationAwakeRequest(action: .on)))
        XCTAssertEqual(request(["awake", "off"])?.awake, AutomationAwakeRequest(action: .off))
        XCTAssertEqual(request(["awake", "status"])?.awake, AutomationAwakeRequest(action: .status))
        XCTAssertEqual(request(["awake", "on", "--for", "30m"])?.awake, AutomationAwakeRequest(action: .on, seconds: 1800))
        XCTAssertEqual(usage(["awake"]), L10n.automationUsage(L10n.automationUsageNoAwakeAction))
        XCTAssertEqual(usage(["awake", "enable"]), L10n.automationUsage(L10n.automationUsageUnknownAwakeAction("enable")))
        XCTAssertEqual(usage(["awake", "off", "--for", "1h"]), L10n.automationUsage(L10n.automationUsageForOnlyOn))
        XCTAssertEqual(usage(["awake", "on", "--for"]), L10n.automationUsage(L10n.automationUsageMissingValue("--for")))
        XCTAssertNotNil(usage(["awake", "on", "1h"]))
        XCTAssertNotNil(usage(["awake", "status", "--display", "x"]))
    }

    func testDurationFormats() {
        let accepted: [String: Int] = ["0": 0, "1": 1, "90": 90, "7200": 7200, "30m": 1800, "2h": 7200, "1h30m": 5400,
                                       "1h30m15s": 5415, "90s": 90, "45M": 2700, "1H": 3600, "120m": 7200]
        for (text, seconds) in accepted {
            XCTAssertEqual(AutomationCLI.awakeDuration(text), seconds, text)
        }
        for text in ["", "-5", "7201", "3h", "2h1s", "121m", "0m", "0h0m", "30m2h", "1h1h", "h", "1.5h", "30 m",
                     "1d", "abc", "１０"] {
            XCTAssertNil(AutomationCLI.awakeDuration(text), text)
        }
        XCTAssertEqual(usage(["awake", "on", "--for", "3h"]), L10n.automationUsage(L10n.automationUsageBadDuration("3h")))
    }

    func testUsageErrorsExitWithUsageCode() {
        let outcome = AutomationCLI.execute(["awake", "on", "--for", "3h"], currentDirectory: "/", isDevelopmentBuild: false,
                                            bundleInfo: [:], bundleID: "test") { _, _, _ in
            XCTFail("a usage error never reaches the app")
            return .failure(.notRunning)
        }
        XCTAssertEqual(outcome.code, AutomationExitCode.usage)
        XCTAssertEqual(outcome.stdout, "")
    }

    func testRequestsRoundTripTheWire() throws {
        for request in [
            AutomationRequest(operation: .proxy, proxy: AutomationProxyRequest(action: .shareSet, port: 1, engine: .builtIn,
                                                                               serviceName: "", auth: false, username: "u")),
            AutomationRequest(operation: .awake, awake: AutomationAwakeRequest(action: .on, seconds: 0)),
        ] {
            let data = try AutomationWire.encode(request)
            XCTAssertEqual(try AutomationWire.decodeRequest(data.dropLast()), request)
            XCTAssertEqual(request.version, 1, "optional bodies keep protocol version 1")
        }
    }
}
