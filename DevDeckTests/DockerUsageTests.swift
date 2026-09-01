import XCTest
@testable import DevDeck

final class DockerUsageTests: XCTestCase {

    // Real `docker system df --format '{{json .}}'` from the colima VM (build cache just pruned).
    private let colima = """
    {"Active":"4","Reclaimable":"2.355GB (25%)","Size":"9.339GB","TotalCount":"26","Type":"Images"}
    {"Active":"4","Reclaimable":"0B (0%)","Size":"8.106MB","TotalCount":"4","Type":"Containers"}
    {"Active":"3","Reclaimable":"340.1MB (0%)","Size":"45.54GB","TotalCount":"8","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Build Cache"}
    """

    // Same, from inside the minikube node (build cache has no percentage in docker's output).
    private let minikube = """
    {"Active":"34","Reclaimable":"9.617GB (57%)","Size":"16.87GB","TotalCount":"166","Type":"Images"}
    {"Active":"92","Reclaimable":"177.4MB (49%)","Size":"356.9MB","TotalCount":"150","Type":"Containers"}
    {"Active":"29","Reclaimable":"1.192GB (99%)","Size":"1.192GB","TotalCount":"43","Type":"Local Volumes"}
    {"Active":"14","Reclaimable":"11.97GB","Size":"15.9GB","TotalCount":"251","Type":"Build Cache"}
    """

    // The combined probe output: the summary lines, then the volume listing, then the volumes held
    // by *running* containers. docker prints the array without a trailing newline, so the marker
    // lands on the same line — the parser splits on the substring, not line by line.
    private let combined = """
    {"Active":"4","Reclaimable":"507.9kB (5%)","Size":"8.614MB","TotalCount":"35","Type":"Containers"}
    {"Active":"34","Reclaimable":"340.9MB (0%)","Size":"72.38GB","TotalCount":"48","Type":"Local Volumes"}
    ---devdeck---
    [{"Labels":"com.docker.volume.anonymous=","Links":"1","Name":"aaa","Size":"2.692GB"},\
    {"Labels":"com.docker.volume.anonymous=","Links":"0","Name":"bbb","Size":"253.7kB"},\
    {"Labels":"com.docker.volume.anonymous=","Links":"1","Name":"ccc","Size":"1.78GB"},\
    {"Labels":"com.docker.compose.project=krill","Links":"0","Name":"krill_pgdata","Size":"50.17MB"},\
    {"Labels":"created_by.minikube.sigs.k8s.io=true","Links":"1","Name":"minikube","Size":"45.12GB"}]---devdeck---
    ccc

    minikube
    """

    func testParseSizeDecimalUnits() {
        XCTAssertEqual(DockerUsage.parseSize("9.617GB (57%)"), 9_617_000_000)
        XCTAssertEqual(DockerUsage.parseSize("11.97GB"), 11_970_000_000)
        XCTAssertEqual(DockerUsage.parseSize("177.4MB (49%)"), 177_400_000)
        XCTAssertEqual(DockerUsage.parseSize("105.7kB"), 105_700)
        XCTAssertEqual(DockerUsage.parseSize("0B"), 0)
        XCTAssertEqual(DockerUsage.parseSize("0B (0%)"), 0)
        XCTAssertEqual(DockerUsage.parseSize("1.5TB"), 1_500_000_000_000)
    }

    func testParseSizeRejectsGarbage() {
        XCTAssertNil(DockerUsage.parseSize(""))
        XCTAssertNil(DockerUsage.parseSize("abc"))
        XCTAssertNil(DockerUsage.parseSize("12"))        // no unit
        XCTAssertNil(DockerUsage.parseSize("12XB"))
        XCTAssertNil(DockerUsage.parseSize("(57%)"))
    }

    func testParseColimaOutput() throws {
        let u = try XCTUnwrap(DockerUsage.parse(colima))
        XCTAssertEqual(u.images, DockerUsageRow(total: 26, active: 4,
                                                sizeBytes: 9_339_000_000, reclaimableBytes: 2_355_000_000))
        XCTAssertEqual(u.containers?.total, 4)
        XCTAssertEqual(u.volumes?.reclaimableBytes, 340_100_000)
        XCTAssertEqual(u.buildCache, DockerUsageRow(total: 0, active: 0, sizeBytes: 0, reclaimableBytes: 0))
    }

    func testParseMinikubeOutput() throws {
        let u = try XCTUnwrap(DockerUsage.parse(minikube))
        XCTAssertEqual(u.buildCache?.reclaimableBytes, 11_970_000_000)
        XCTAssertEqual(u.buildCache?.active, 14)
        XCTAssertEqual(u.containers?.total, 150)
        XCTAssertEqual(u.containers?.active, 92)
    }

    func testParseTolerance() {
        XCTAssertNil(DockerUsage.parse(""))
        XCTAssertNil(DockerUsage.parse("Cannot connect to the Docker daemon"))
        // A partial listing still yields what parsed; unknown types are ignored, not fatal.
        let partial = """
        {"Active":"1","Reclaimable":"1GB (50%)","Size":"2GB","TotalCount":"2","Type":"Images"}
        {"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Something New"}
        garbage line
        """
        let u = DockerUsage.parse(partial)
        XCTAssertEqual(u?.images?.sizeBytes, 2_000_000_000)
        XCTAssertNil(u?.containers)
        XCTAssertNil(u?.buildCache)
    }

    func testEstimatesPerAction() throws {
        let u = try XCTUnwrap(DockerUsage.parse(minikube))
        // Dead containers + their anonymous volumes: both reclaimable figures together.
        XCTAssertEqual(u.estimate(for: .deadContainers), 177_400_000 + 1_192_000_000)
        XCTAssertEqual(u.estimate(for: .buildCache), 11_970_000_000)
        XCTAssertEqual(u.estimate(for: .unusedImages), 9_617_000_000)
        // Missing rows → no estimate (the button still works, it just can't promise a number).
        XCTAssertNil(DockerUsage(images: nil, containers: nil, volumes: nil, buildCache: nil)
                        .estimate(for: .buildCache))
    }

    func testFormatBytesBinaryLikeTheDiskCell() {
        XCTAssertEqual(DockerUsage.formatBytes(0), "0 MB")
        XCTAssertEqual(DockerUsage.formatBytes(340_100_000), "324 MB")
        XCTAssertEqual(DockerUsage.formatBytes(11_970_000_000), "11.1 GB")
        XCTAssertEqual(DockerUsage.formatBytes(1_073_741_824), "1.0 GB")
    }

    // MARK: - volumes the dead containers still hold

    func testPruneableVolumesSkipNamedOnesAndThoseHeldByRunningContainers() throws {
        let u = try XCTUnwrap(DockerUsage.parse(combined))
        // aaa (held by a stopped container) + bbb (already dangling). ccc is held by a running
        // container; krill_pgdata and minikube are named — `volume prune` without -a spares them.
        XCTAssertEqual(u.pruneableVolumeBytes, 2_692_000_000 + 253_700)
    }

    func testDeadContainerEstimateCountsVolumesStoppedContainersStillHold() throws {
        let u = try XCTUnwrap(DockerUsage.parse(combined))
        // Not docker's 340.9MB: that figure both misses the volumes stopped containers still link
        // and counts named dangling ones the button will not delete.
        XCTAssertEqual(u.estimate(for: .deadContainers), 507_900 + 2_692_000_000 + 253_700)
    }

    func testDeadContainerEstimateFallsBackToDockerReclaimableWithoutDetail() throws {
        let u = try XCTUnwrap(DockerUsage.parse(colima))
        XCTAssertNil(u.pruneableVolumeBytes)
        XCTAssertEqual(u.estimate(for: .deadContainers), 0 + 340_100_000)
    }

    func testGarbledVolumeListingFallsBackInsteadOfReportingZero() throws {
        let garbled = combined.replacingOccurrences(of: "[{\"Labels\"", with: "not json {\"Labels\"")
        let u = try XCTUnwrap(DockerUsage.parse(garbled))
        XCTAssertNil(u.pruneableVolumeBytes)
        XCTAssertEqual(u.estimate(for: .deadContainers), 507_900 + 340_900_000)
    }

    func testNoRunningContainersLeavesEveryAnonymousVolumePruneable() throws {
        let idle = combined.components(separatedBy: "---devdeck---")[0...1]
            .joined(separator: "---devdeck---") + "---devdeck---\n"
        let u = try XCTUnwrap(DockerUsage.parse(idle))
        XCTAssertEqual(u.pruneableVolumeBytes, 2_692_000_000 + 253_700 + 1_780_000_000)
    }

    func testProbeScriptReachesMinikubeAsASingleArgument() {
        let colima = LiveDockerUsageProbe.invocation(.colima)
        XCTAssertEqual(colima.binary, "colima")
        XCTAssertEqual(Array(colima.args.prefix(4)), ["ssh", "--", "sh", "-c"])
        let minikube = LiveDockerUsageProbe.invocation(.minikube)
        XCTAssertEqual(minikube.binary, "minikube")
        XCTAssertEqual(minikube.args.count, 3, "minikube joins argv verbatim — the script must stay one word")
        XCTAssertTrue(minikube.args[2].contains(DockerUsage.sectionMarker))
    }

    func testNestedDaemonVolumeSizeIsPickedOutOfTheListing() throws {
        let u = try XCTUnwrap(DockerUsage.parse(combined))
        // The `minikube` volume is the node's whole disk — colima counts it among its volumes, so
        // the page has to name it or the two daemons look like they double-count the same bytes.
        XCTAssertEqual(u.nestedDaemonVolumeBytes, 45_120_000_000)
    }

    func testNestedDaemonVolumeIsZeroWhenNothingCarriesTheLabel() throws {
        let noNode = combined.replacingOccurrences(of: "created_by.minikube.sigs.k8s.io=true",
                                                   with: "com.docker.compose.project=guild")
        let u = try XCTUnwrap(DockerUsage.parse(noNode))
        XCTAssertEqual(u.nestedDaemonVolumeBytes, 0)
    }

    func testNestedDaemonVolumeIsUnknownWithoutTheDetailListing() throws {
        XCTAssertNil(try XCTUnwrap(DockerUsage.parse(colima)).nestedDaemonVolumeBytes)
    }
}
