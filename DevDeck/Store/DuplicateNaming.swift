import Foundation

/// Builds the name for a duplicated command or chain: `deploy` → `deploy (copy)` → `deploy (copy 2)`.
///
/// Pure, and deliberately free of `L10n`: the marker word arrives as a parameter, so the tests can
/// cover both languages without touching the app-wide language setting.
enum DuplicateNaming {

    /// The lowest free copy name for `base`.
    ///
    /// `base` is the original's name, raw — a trailing copy marker is stripped here, so duplicating
    /// a copy yields `X (copy 2)` rather than `X (copy) (copy)`. Every marker in `knownMarkers` is
    /// recognized, not just the one being written: names live in `config.json` and outlive a
    /// language switch, and matching only the active marker would produce a duplicate name.
    static func nextName(base: String, marker: String,
                         knownMarkers: [String], existing: Set<String>) -> String {
        let root = strippingMarker(from: base, knownMarkers: knownMarkers)
        var index = 1
        while true {
            let candidate = name(root: root, marker: marker, index: index)
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }

    private static func name(root: String, marker: String, index: Int) -> String {
        let suffix = index == 1 ? "(\(marker))" : "(\(marker) \(index))"
        return root.isEmpty ? suffix : "\(root) \(suffix)"
    }

    /// Drops a trailing `(copy)` / `(копия 3)`. Anchored at the end and preceded by whitespace or
    /// the start of the string — a marker in the middle of a name is part of that name.
    private static func strippingMarker(from name: String, knownMarkers: [String]) -> String {
        let alternatives = knownMarkers
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        guard !alternatives.isEmpty,
              let regex = try? NSRegularExpression(
                  pattern: "(?:^|\\s)\\((?:\(alternatives))(?: \\d+)?\\)$")
        else { return name }
        let range = NSRange(name.startIndex..., in: name)
        return regex.stringByReplacingMatches(in: name, range: range, withTemplate: "")
    }
}
