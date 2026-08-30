import Foundation

/// A session title recorded in a transcript, with the file's mtime for ordering.
struct TranscriptTitle: Equatable, Sendable {
    var aiTitle: String
    var sessionID: String
    var modifiedAt: Date
}

/// Claude Code names a project directory after its path with every "/" turned into "-".
enum ClaudeProjectSlug {
    static func slug(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }
}

/// Pulls the session title out of transcript lines.
///
/// Deliberately lenient: `ai-title` is Claude Code's internal format, and a change there must
/// degrade into "title not found" rather than a crash or a wrong session id.
enum TranscriptTitleScanner {
    static func lastTitle(in lines: [String]) -> (aiTitle: String, sessionID: String)? {
        for line in lines.reversed() where line.contains("\"type\":\"ai-title\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = object["aiTitle"] as? String,
                  let sessionID = object["sessionId"] as? String,
                  !title.isEmpty, !sessionID.isEmpty else { continue }
            return (title, sessionID)
        }
        return nil
    }
}

/// Titles known for a working directory — behind a protocol so the resolver is tested with a fake.
protocol TranscriptIndexing: Sendable {
    /// Newest transcript first.
    func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle]
}

/// Scans `~/.claude/projects`. Results are cached per (file, mtime), so only the first pass over a
/// large transcript is expensive and the once-a-minute snapshot stays cheap.
final class LiveTranscriptIndex: TranscriptIndexing, @unchecked Sendable {
    private let projectsRoot: URL
    private let lock = NSLock()
    private var cache: [URL: (modifiedAt: Date, title: TranscriptTitle?)] = [:]

    init(projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")) {
        self.projectsRoot = projectsRoot
    }

    func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle] {
        guard let directory = projectDirectory(for: workingDirectory),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { title(of: $0) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// The slug is the fast path. If Claude ever changes how it names project directories, fall back
    /// to scanning every project and matching the `cwd` its transcripts record — slower, but the
    /// feature degrades into a delay rather than into silence.
    private func projectDirectory(for workingDirectory: String) -> URL? {
        let bySlug = projectsRoot.appendingPathComponent(ClaudeProjectSlug.slug(for: workingDirectory))
        if FileManager.default.fileExists(atPath: bySlug.path) { return bySlug }
        guard let projects = try? FileManager.default.contentsOfDirectory(
                at: projectsRoot, includingPropertiesForKeys: nil) else { return nil }
        let needle = "\"cwd\":\"\(workingDirectory)\""
        return projects.first { project in
            guard let files = try? FileManager.default.contentsOfDirectory(
                    at: project, includingPropertiesForKeys: nil) else { return false }
            return files.contains { file in
                file.pathExtension == "jsonl"
                    && ((try? String(contentsOf: file, encoding: .utf8))?.contains(needle) ?? false)
            }
        }
    }

    private func title(of file: URL) -> TranscriptTitle? {
        let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        lock.lock()
        if let cached = cache[file], cached.modifiedAt == modifiedAt {
            lock.unlock()
            return cached.title
        }
        lock.unlock()

        var result: TranscriptTitle?
        if let content = try? String(contentsOf: file, encoding: .utf8),
           let found = TranscriptTitleScanner.lastTitle(in: content.components(separatedBy: "\n")) {
            result = TranscriptTitle(aiTitle: found.aiTitle, sessionID: found.sessionID, modifiedAt: modifiedAt)
        }
        lock.lock()
        cache[file] = (modifiedAt, result)
        lock.unlock()
        return result
    }
}
