import XCTest
@testable import DevDeck

/// Where a development build keeps its data: `--dev-data-directory` first, then the
/// `DevDeckDevDataDirectory` Info.plist key written when the acceptance build is packaged, then
/// none (a normal launch). The key is what keeps a launch by Shortcuts, launchd or Finder — which
/// pass no arguments — away from the installed DevDeck's config.
final class AppRuntimeDevelopmentDirectoryTests: XCTestCase {

    private let installed = URL(fileURLWithPath: "/Users/someone/Library/Application Support/DevDeck", isDirectory: true)
    private let key = AppRuntime.developmentDirectoryInfoKey

    private func resolve(_ arguments: [String], _ info: [String: Any] = [:]) -> AppRuntime.DevelopmentDirectory {
        AppRuntime.resolveDevelopmentDirectory(arguments: ["/path/DevDeck"] + arguments, info: info, installed: installed)
    }

    func testNeitherMeansANormalLaunch() {
        XCTAssertEqual(resolve([]), .none)
        XCTAssertEqual(resolve([], [key: ""]), .none)
    }

    func testArgument() {
        XCTAssertEqual(resolve(["--dev-data-directory", "/tmp/dev"]), .directory(URL(fileURLWithPath: "/tmp/dev", isDirectory: true)))
    }

    func testInfoKeyWithoutArguments() {
        XCTAssertEqual(resolve([], [key: "/tmp/packaged"]), .directory(URL(fileURLWithPath: "/tmp/packaged", isDirectory: true)))
    }

    func testArgumentWinsOverTheKey() {
        XCTAssertEqual(resolve(["--dev-data-directory", "/tmp/dev"], [key: "/tmp/packaged"]),
                       .directory(URL(fileURLWithPath: "/tmp/dev", isDirectory: true)))
    }

    func testRejectsRelativeMissingAndInstalled() {
        guard case .invalid = resolve(["--dev-data-directory"]) else { return XCTFail("flag without a value") }
        guard case .invalid = resolve(["--dev-data-directory", "dev"]) else { return XCTFail("relative argument") }
        guard case .invalid = resolve([], [key: "dev"]) else { return XCTFail("relative key") }
        guard case .invalid = resolve([], [key: installed.path]) else { return XCTFail("the installed directory") }
    }

    func testTheHostedTestBuildCarriesNoKey() {
        XCTAssertNil(Bundle.main.infoDictionary?[key], "the project itself must not set it — only the acceptance packaging")
    }
}
