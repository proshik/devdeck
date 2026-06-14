import Foundation

/// Pure (de)serialization layer for `Config` — no filesystem access.
/// Extracted separately so round-trip and decoding robustness can be tested
/// deterministically, without filesystem timing concerns.
enum ConfigCodec {
    /// Stable, human-readable output: sorted keys + pretty-print,
    /// so the file stays diff-friendly and hand-editable.
    static func encode(_ config: Config) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config)
    }

    static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }
}
