import Foundation

protocol DiskScanStoring: Sendable {
    func load() -> DiskScanResult?
    func save(_ result: DiskScanResult)
}

/// `disk-scan.json` in DevDeck's data directory — the last finished scan, shown until the next one.
///
/// Through `PrivateFile` (0600 in a 0700 directory): it lists the user's project folders and what
/// they hold. A missing, malformed or older-version file reads as "never scanned" — it is
/// disposable, a rescan rebuilds it.
struct DiskScanStore: DiskScanStoring {
    let url: URL

    init(url: URL = PrivateFile.applicationSupportDirectory.appendingPathComponent("disk-scan.json")) {
        self.url = url
    }

    func load() -> DiskScanResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let result = try? decoder.decode(DiskScanResult.self, from: data),
              result.version == DiskScanResult.currentVersion, result.isConsistent else { return nil }
        return result
    }

    func save(_ result: DiskScanResult) {
        do {
            try PrivateFile.makeDirectory(at: url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(result).write(to: url, options: .atomic)
            PrivateFile.restrict(url)
        } catch {
            DiagnosticLog.shared.log("Disk scan: could not save \(url.path) — \(error.localizedDescription)", level: .warn)
        }
    }
}
