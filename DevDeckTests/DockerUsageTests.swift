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
}
