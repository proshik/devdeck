import Foundation

/// The volume a path lives on: used and total, in the same shape (and format) as the VM disk.
protocol VolumeUsageProbing: Sendable {
    func sample(_ path: String) -> VMDiskInfo?
}

/// `statfs` through the URL resource values: no process, answers at once. "Used" is total minus
/// what is available now — not "available for important usage", which counts purgeable space as
/// free and would make the bar disagree with what a `cp` actually finds.
struct LiveVolumeUsageProbe: VolumeUsageProbing {
    func sample(_ path: String) -> VMDiskInfo? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacity else { return nil }
        let used = max(0, total - available)
        return VMDiskInfo(usedBytes: UInt64(used), totalBytes: UInt64(total))
    }
}
