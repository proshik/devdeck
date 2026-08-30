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
    /// Newest transcript first — and that is a contract, not a convenience: `SessionResolver`
    /// resolves a tie between two sessions with the same title by taking the first candidate, so
    /// the ordering here is the whole of "the most recent session wins".
    func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle]
}

/// Scans `~/.claude/projects`. Two caches keep the once-a-minute snapshot cheap: titles per
/// (file, mtime), so only the first pass over a large transcript is expensive, and project
/// directories per working directory, so the full-corpus fallback below runs at most once per
/// directory per app run.
final class LiveTranscriptIndex: TranscriptIndexing, @unchecked Sendable {
    private let projectsRoot: URL
    private let lock = NSLock()
    private var cache: [URL: (modifiedAt: Date, title: TranscriptTitle?)] = [:]
    /// Working directory → its project directory, **including the misses**. A negative result is
    /// the expensive one to recompute: a plain shell tab in `~/Downloads` has no project directory
    /// and never will, and without this entry every capture would read the whole corpus again
    /// looking for it. `URL?` values with a `[String: URL?]` subscript: "no entry" and "an entry
    /// saying nothing matched" are different answers here.
    private var directories: [String: URL?] = [:]

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

    /// The slug is the fast path; the fallback below reads **every** transcript in
    /// `~/.claude/projects` — on this machine 711 files and 1.1 GB. It has to be answered once per
    /// working directory and then remembered, misses included: a tab sitting in a directory Claude
    /// has never seen (a plain shell, or a session started from a subdirectory) is exactly the
    /// input that reaches the fallback, and it would otherwise do that once a minute forever.
    ///
    /// The lock is never held across a file read, same discipline as the title cache: take it to
    /// look, drop it to work, take it again to record.
    private func projectDirectory(for workingDirectory: String) -> URL? {
        let bySlug = projectsRoot.appendingPathComponent(ClaudeProjectSlug.slug(for: workingDirectory))
        lock.lock()
        let cached = directories[workingDirectory]
        lock.unlock()

        if let cached {
            if let directory = cached { return directory }
            // A remembered miss, re-checked against the slug only — one `stat`, no corpus scan.
            // That is what lets a session started in a brand-new directory resolve later in the
            // same app run, without ever paying for the fallback twice.
            guard FileManager.default.fileExists(atPath: bySlug.path) else { return nil }
            remember(bySlug, for: workingDirectory)
            return bySlug
        }

        let resolved = FileManager.default.fileExists(atPath: bySlug.path) ? bySlug : scan(for: workingDirectory)
        remember(resolved, for: workingDirectory)
        return resolved
    }

    private func remember(_ directory: URL?, for workingDirectory: String) {
        lock.lock()
        directories[workingDirectory] = directory
        lock.unlock()
    }

    /// The fallback: if Claude ever changes how it names project directories, match on the `cwd`
    /// its transcripts record — slower, but the feature degrades into a delay rather than silence.
    private func scan(for workingDirectory: String) -> URL? {
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
