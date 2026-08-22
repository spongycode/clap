import Foundation
import ClapCore
import os

/// Watches the shell history file (zsh/bash) and ingests newly appended
/// commands. Polling (2 s) keeps it simple and robust against zsh's
/// rewrite-on-trim behavior:
///
/// - size grew        -> read only the appended bytes, parse, ingest
/// - inode changed or
///   size shrank      -> zsh rewrote/trimmed the file; skip to the new EOF
///                       (history already ingested; backfill covers gaps)
///
/// Never logs command text — metadata only.
actor ShellHistoryMonitor {

    private let store: ClipboardStore
    private let logger = Logger(subsystem: ClapIdentity.bundleID, category: "shell")
    private static let pollIntervalNanos = Timing.shellHistoryPollNanos

    private var pollTask: Task<Void, Never>?
    private var enabled = true
    private var fileURL: URL?
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    private var carry = Data()   // trailing partial line from the last read

    init(store: ClipboardStore) {
        self.store = store
    }

    func start() async {
        guard pollTask == nil else { return }
        await refreshConfig()

        // One-time auto import of existing shell history if not yet imported.
        // The marker is only set on success so a failed first import retries
        // on the next launch.
        let alreadyImported = ((try? await store.config(ConfigKey.shellInitialImported)) ?? "0") == "1"
        if !alreadyImported, enabled, let url = fileURL {
            let imported = await autoImportInitialHistory(from: url)
            if imported {
                try? await store.setConfig(ConfigKey.shellInitialImported, value: "1")
            }
        }

        if let url = fileURL, let (ino, size) = Self.fileStat(url) {
            inode = ino
            offset = size
        }
        pollTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
            }
        }
        logger.info("shell history monitor started")
    }

    private func autoImportInitialHistory(from url: URL) async -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let parsed = ShellHistoryParser.parse(data)
        guard !parsed.isEmpty else { return false }
        let batch = parsed.map { (text: $0.text, executedAt: $0.executedAt) }
        do {
            let result = try await store.ingestShellBatch(batch, source: url.lastPathComponent)
            logger.info("initial auto-import completed: \(result.imported) new, \(result.merged) merged")
            IPC.post(.storeChanged)
            return true
        } catch {
            logger.error("initial auto-import failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshConfig() async {
        enabled = ((try? await store.config(ConfigKey.shellEnabled)) ?? "1") == "1"
        let configured = (try? await store.config("shell.histfile")) ?? ""
        if !configured.isEmpty {
            fileURL = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        } else {
            fileURL = ShellHistoryParser.defaultHistoryFile()
        }
    }

    private func poll() async {
        guard enabled, let url = fileURL else { return }
        guard let (currentInode, size) = Self.fileStat(url) else { return }

        if currentInode != inode || size < offset {
            // Rewritten (zsh trim) or rotated: don't re-ingest, just re-anchor.
            inode = currentInode
            offset = size
            carry.removeAll()
            return
        }
        guard size > offset else { return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let appended = try handle.read(upToCount: Int(size - offset)) ?? Data()
            offset = size

            var chunk = carry + appended
            carry.removeAll()
            // Hold back a trailing partial line until its newline arrives.
            if let lastNewline = chunk.lastIndex(of: 0x0A) {
                let after = chunk.index(after: lastNewline)
                if after < chunk.endIndex {
                    carry = chunk[after...]
                    chunk = chunk[..<after]
                }
            } else {
                carry = chunk
                return
            }

            let commands = ShellHistoryParser.parse(chunk)
            guard !commands.isEmpty else { return }
            let batch = commands.map { (text: $0.text, executedAt: $0.executedAt) }
            if let result = try? await store.ingestShellBatch(batch, source: url.lastPathComponent),
               (result.imported + result.merged) > 0 {
                logger.debug("ingested \(result.imported + result.merged, privacy: .public) shell commands")
                IPC.post(.storeChanged)
            }
        } catch {
            logger.error("shell history read failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func fileStat(_ url: URL) -> (inode: UInt64, size: UInt64)? {
        var info = Darwin.stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return (UInt64(info.st_ino), UInt64(info.st_size))
    }
}
