import Foundation

/// Watches the config file via TWO `DispatchSource` sources:
///
/// 1. **Parent directory** — catches atomic replacement (temp file + `rename`,
///    as used by editors and our own `save`): replacement changes the file's inode,
///    but the directory inode is stable and survives it.
/// 2. **The file itself** — catches in-place overwrites (truncate+write: `echo >`, `sed -i`,
///    scripts): these don't touch the directory, so the event comes only from the file's vnode.
///    After each directory event the file source is re-attached to the (possibly
///    new) inode — otherwise it would be orphaned after the first atomic replacement.
///
/// Events are debounced (a burst of create+rename+attr collapses into a single reload)
/// and delivered on the main queue — where the `@MainActor` store lives.
///
/// Deferred (outside Stage 1): re-arm when the directory itself is deleted/renamed —
/// after that the source is stuck on a dead inode and no events arrive until restart.
/// In normal usage `~/Library/Application Support/DevDeck` is stable.
final class FileWatcher {
    private let fileURL: URL
    private let directoryURL: URL
    private let onChange: () -> Void
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "capital.frontier.DevDeck.FileWatcher", qos: .utility)

    private var source: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    init(fileURL: URL, debounceInterval: TimeInterval = 0.15, onChange: @escaping () -> Void) {
        self.fileURL = fileURL
        self.directoryURL = fileURL.deletingLastPathComponent()
        self.onChange = onChange
        self.debounceInterval = debounceInterval
    }

    func start() {
        queue.async { [weak self] in self?.arm() }
    }

    func stop() {
        queue.async { [weak self] in self?.disarm() }
    }

    deinit {
        // Ensures sources are cancelled (and fd closed via cancel-handler),
        // even if the owner dropped the reference before stop() was called.
        source?.cancel()
        fileSource?.cancel()
    }

    // MARK: private (all on serial queue)

    private func arm() {
        disarm()
        let dirFD = open(directoryURL.path, O_EVTONLY)
        guard dirFD >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        // Directory event means the file may have been replaced via rename → re-attach
        // the file source to the current inode, otherwise in-place writes after
        // replacement would go undetected.
        src.setEventHandler { [weak self] in
            self?.armFileSource()
            self?.scheduleReload()
        }
        // fd is captured BY VALUE: closing does not depend on self's lifetime,
        // so the descriptor is closed even if the watcher has already been deallocated.
        src.setCancelHandler { close(dirFD) }
        source = src
        src.resume()

        armFileSource()

        // Primer: one reload strictly AFTER the source is live.
        // Closes the window between the store's initial reload() and resume (an external
        // write at that moment would otherwise be lost). Idempotent — Equatable guard suppresses no-ops.
        let primer = onChange
        DispatchQueue.main.async { primer() }
    }

    /// (Re-)attach the vnode source to the file's current inode. If the file does not exist, silently skip:
    /// when it appears, a directory event will trigger another attempt.
    private func armFileSource() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(fd) }
        fileSource = src
        src.resume()
    }

    private func disarm() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()   // cancel-handler will close the fd
        source = nil
        fileSource?.cancel()
        fileSource = nil
    }

    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onChange() }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
