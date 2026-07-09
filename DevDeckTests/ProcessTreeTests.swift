import XCTest
@testable import DevDeck

final class ProcessTreeTests: XCTestCase {

    // MARK: PATH augmentation
    // A GUI app launched by launchd inherits a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin),
    // so colima/minikube can't find their own helpers (limactl, docker). ProcessTree must
    // prepend the Homebrew bin dirs.

    func testPrependsHomebrewDirsToMinimalPATH() {
        let result = ProcessTree.augmentedPATH("/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(result, "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testDoesNotDuplicateDirsAlreadyPresent() {
        let existing = "/opt/homebrew/bin:/usr/bin:/bin"
        let result = ProcessTree.augmentedPATH(existing)
        // /opt/homebrew/bin already there → only /usr/local/bin is prepended.
        XCTAssertEqual(result, "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
    }

    func testHandlesNilAndEmptyPATH() {
        XCTAssertEqual(ProcessTree.augmentedPATH(nil), "/opt/homebrew/bin:/usr/local/bin")
        XCTAssertEqual(ProcessTree.augmentedPATH(""), "/opt/homebrew/bin:/usr/local/bin")
    }

    func testLeavesFullPATHUnchangedWhenBothPresent() {
        let existing = "/opt/homebrew/bin:/usr/local/bin:/usr/bin"
        XCTAssertEqual(ProcessTree.augmentedPATH(existing), existing)
    }
}
