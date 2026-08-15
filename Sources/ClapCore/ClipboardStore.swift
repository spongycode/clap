import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The single entry point. An actor so all DB access is serialized per process.
/// Multi-process safety comes from SQLite WAL + busy_timeout.
///
/// Security note: clipboard content is never logged anywhere in this module.
public actor ClipboardStore {

    public nonisolated let dataDir: URL
    private let db: Database

    private nonisolated var imagesDir: URL {
        dataDir.appendingPathComponent("images", isDirectory: true)
    }
    private nonisolated var thumbnailsDir: URL {
        dataDir.appendingPathComponent("thumbnails", isDirectory: true)
    }

    public init(dataDir: URL? = nil) throws {
        let resolved = Self.resolveDataDir(dataDir)
        self.dataDir = resolved
        let fm = FileManager.default
        // Clipboard data is sensitive: owner-only on everything we create.
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try fm.createDirectory(at: resolved, withIntermediateDirectories: true,
                               attributes: ownerOnly)
        try fm.createDirectory(at: resolved.appendingPathComponent("images", isDirectory: true),
                               withIntermediateDirectories: true, attributes: ownerOnly)
        try fm.createDirectory(at: resolved.appendingPathComponent("thumbnails", isDirectory: true),
                               withIntermediateDirectories: true, attributes: ownerOnly)
        // Pre-existing dirs keep their old mode; tighten them too.
        for dir in [resolved, resolved.appendingPathComponent("images"),
                    resolved.appendingPathComponent("thumbnails")] {
            try? fm.setAttributes(ownerOnly, ofItemAtPath: dir.path)
        }
        self.db = try Database(path: resolved.appendingPathComponent("clap.sqlite").path)
        try db.migrate()
        // The DB (and its WAL/SHM siblings) hold clipboard text.
        for suffix in ["", "-wal", "-shm"] {
            let path = resolved.appendingPathComponent("clap.sqlite\(suffix)").path
            if fm.fileExists(atPath: path) {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
    }

    /// Resolution order: explicit param > CLAP_DATA_DIR env > default location.
    nonisolated static func resolveDataDir(_ explicit: URL?) -> URL {
        if let explicit { return explicit }
        if let env = ProcessInfo.processInfo.environment["CLAP_DATA_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/clap", isDirectory: true)
    }

    // MARK: - Capture

    @discardableResult
    public func captureText(_ raw: String, sourceApp: String?) throws -> (entry: ClipboardEntry, wasDuplicate: Bool)? {
        let normalized = TextNormalizer.normalize(raw)
        guard !normalized.isEmpty else { return nil }
        // A single entry larger than the whole category budget must never be
        // stored: byte eviction would otherwise delete every older unpinned
        // entry chasing a cap this entry alone exceeds.
        let sizeBytes = Int64(normalized.utf8.count)
        if sizeBytes > (try configInt64("text.max_size")) { return nil }
        let hash = ContentHasher.textHash(normalized)
        let now = Date().timeIntervalSince1970
        let day = Self.dayKey()

        return try db.transaction {
            try incrementCounter("events:\(day)")
            // content equality guards against a (rare) 64-bit hash collision
            // silently discarding unrelated text as a "duplicate".
            if let existing = try firstEntry("type = 'text' AND content_hash = ? AND content = ?",
                                             [.text(hash), .text(normalized)]) {
                try db.run("UPDATE entries SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?",
                           [.double(now), .int(existing.id)])
                try incrementCounter("dups:\(day)")
                guard let updated = try firstEntry("id = ?", [.int(existing.id)]) else {
                    throw ClapCoreError.database(code: 0, message: "entry vanished during capture")
                }
                return (updated, true)
            }
            try db.run("""
                INSERT INTO entries (type, content, image_path, image_format, content_hash,
                                     created_at, last_used_at, size_bytes, is_pinned, use_count, source_app)
                VALUES ('text', ?, NULL, NULL, ?, ?, ?, ?, 0, 1, ?)
                """,
                [.text(normalized), .text(hash), .double(now), .double(now),
                 .int(Int64(normalized.utf8.count)), sourceApp.map(SQLValue.text) ?? .null])
            guard let inserted = try firstEntry("id = ?", [.int(db.lastInsertRowid)]) else {
                throw ClapCoreError.database(code: 0, message: "insert did not produce a row")
            }
            return (inserted, false)
        }
    }

    @discardableResult
    public func captureImage(data: Data, format: String, sourceApp: String?) throws -> (entry: ClipboardEntry, wasDuplicate: Bool)? {
        guard !data.isEmpty else { return nil }
        // Same oversize guard as text: never store an entry bigger than the
        // whole category budget (see captureText).
        if Int64(data.count) > (try configInt64("image.max_size")) { return nil }
        let hash = ContentHasher.imageHash(data)
        let ext = format.lowercased()
        let relativePath = "\(hash).\(ext)"
        let now = Date().timeIntervalSince1970
        let day = Self.dayKey()

        return try db.transaction {
            try incrementCounter("events:\(day)")
            if let existing = try firstEntry("type = 'image' AND content_hash = ?", [.text(hash)]) {
                // Duplicate image: touch only, never rewrite the file.
                try db.run("UPDATE entries SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?",
                           [.double(now), .int(existing.id)])
                try incrementCounter("dups:\(day)")
                guard let updated = try firstEntry("id = ?", [.int(existing.id)]) else {
                    throw ClapCoreError.database(code: 0, message: "entry vanished during capture")
                }
                return (updated, true)
            }
            // New image: write original bytes atomically (temp file + rename).
            let fileURL = imagesDir.appendingPathComponent(relativePath)
            do {
                try data.write(to: fileURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: fileURL.path)
            } catch {
                throw ClapCoreError.io("failed to write image file at \(fileURL.path)")
            }
            do {
                try db.run("""
                    INSERT INTO entries (type, content, image_path, image_format, content_hash,
                                         created_at, last_used_at, size_bytes, is_pinned, use_count, source_app)
                    VALUES ('image', NULL, ?, ?, ?, ?, ?, ?, 0, 1, ?)
                    """,
                    [.text(relativePath), .text(ext), .text(hash), .double(now), .double(now),
                     .int(Int64(data.count)), sourceApp.map(SQLValue.text) ?? .null])
                guard let inserted = try firstEntry("id = ?", [.int(db.lastInsertRowid)]) else {
                    throw ClapCoreError.database(code: 0, message: "insert did not produce a row")
                }
                return (inserted, false)
            } catch {
                // The row rolls back with the transaction; the file must not
                // be left orphaned on disk.
                try? FileManager.default.removeItem(at: fileURL)
                throw error
            }
        }
    }

    // MARK: - Shell history

    /// Ingests one executed shell command (live watcher and backfill both use
    /// this). Dedup merges: re-running a command bumps recency and use_count
    /// instead of inserting a new row. Daily clipboard counters are NOT
    /// touched — commands aren't clipboard events. Returns nil when empty or
    /// oversize.
    @discardableResult
    public func ingestShell(_ command: String, executedAt: Date?,
                            source: String? = nil) throws -> (id: Int64, merged: Bool)? {
        let normalized = TextNormalizer.normalize(command)
        guard !normalized.isEmpty else { return nil }
        let sizeBytes = Int64(normalized.utf8.count)
        if sizeBytes > (try configInt64("shell.max_size")) { return nil }
        let hash = ContentHasher.textHash(normalized)
        let when = executedAt ?? Date()

        return try db.transaction {
            if let existing = try firstEntry("type = 'shell' AND content_hash = ? AND content = ?",
                                             [.text(hash), .text(normalized)]) {
                try db.run("""
                    UPDATE entries SET
                        created_at   = MIN(created_at, ?),
                        last_used_at = MAX(last_used_at, ?),
                        use_count    = use_count + 1
                    WHERE id = ?
                    """,
                    [.double(when.timeIntervalSince1970),
                     .double(when.timeIntervalSince1970), .int(existing.id)])
                return (existing.id, true)
            }
            try db.run("""
                INSERT INTO entries (type, content, image_path, image_format, content_hash,
                                     created_at, last_used_at, size_bytes, is_pinned, use_count, source_app)
                VALUES ('shell', ?, NULL, NULL, ?, ?, ?, ?, 0, 1, ?)
                """,
                [.text(normalized), .text(hash),
                 .double(when.timeIntervalSince1970), .double(when.timeIntervalSince1970),
                 .int(sizeBytes), source.map(SQLValue.text) ?? .null])
            return (db.lastInsertRowid, false)
        }
    }

    /// Ingests a batch of shell commands within a single database transaction.
    @discardableResult
    public func ingestShellBatch(_ commands: [(text: String, executedAt: Date?)],
                                 source: String? = nil) throws -> (imported: Int, merged: Int) {
        guard !commands.isEmpty else { return (0, 0) }
        let maxSize = try configInt64("shell.max_size")
        var imported = 0
        var merged = 0
        try db.transaction {
            for item in commands {
                let normalized = TextNormalizer.normalize(item.text)
                guard !normalized.isEmpty else { continue }
                let sizeBytes = Int64(normalized.utf8.count)
                if sizeBytes > maxSize { continue }
                let hash = ContentHasher.textHash(normalized)
                let when = item.executedAt ?? Date()

                if let existing = try firstEntry("type = 'shell' AND content_hash = ? AND content = ?",
                                                 [.text(hash), .text(normalized)]) {
                    try db.run("""
                        UPDATE entries SET
                            created_at   = MIN(created_at, ?),
                            last_used_at = MAX(last_used_at, ?),
                            use_count    = use_count + 1
                        WHERE id = ?
                        """,
                        [.double(when.timeIntervalSince1970),
                         .double(when.timeIntervalSince1970), .int(existing.id)])
                    merged += 1
                } else {
                    try db.run("""
                        INSERT INTO entries (type, content, image_path, image_format, content_hash,
                                             created_at, last_used_at, size_bytes, is_pinned, use_count, source_app)
                        VALUES ('shell', ?, NULL, NULL, ?, ?, ?, ?, 0, 1, ?)
                        """,
                        [.text(normalized), .text(hash),
                         .double(when.timeIntervalSince1970), .double(when.timeIntervalSince1970),
                         .int(sizeBytes), source.map(SQLValue.text) ?? .null])
                    imported += 1
                }
            }
        }
        return (imported, merged)
    }

    // MARK: - Import

    /// Imports a text entry from another clipboard manager, preserving its
    /// history metadata. Unlike capture, this does not bump daily counters
    /// (imported rows are not today's clipboard events). Duplicates merge:
    /// earliest created_at, latest last_used_at, summed use_count, pin wins.
    /// Returns nil when the text is empty after normalization or oversize.
    @discardableResult
    public func importText(_ raw: String, createdAt: Date, lastUsedAt: Date,
                           useCount: Int, pinned: Bool, sourceApp: String?) throws -> (id: Int64, merged: Bool)? {
        let normalized = TextNormalizer.normalize(raw)
        guard !normalized.isEmpty else { return nil }
        let sizeBytes = Int64(normalized.utf8.count)
        if sizeBytes > (try configInt64("text.max_size")) { return nil }
        let hash = ContentHasher.textHash(normalized)

        return try db.transaction {
            if let existing = try firstEntry("type = 'text' AND content_hash = ? AND content = ?",
                                             [.text(hash), .text(normalized)]) {
                try mergeImported(into: existing.id, createdAt: createdAt,
                                  lastUsedAt: lastUsedAt, useCount: useCount, pinned: pinned)
                return (existing.id, true)
            }
            try db.run("""
                INSERT INTO entries (type, content, image_path, image_format, content_hash,
                                     created_at, last_used_at, size_bytes, is_pinned, use_count, source_app)
                VALUES ('text', ?, NULL, NULL, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(normalized), .text(hash),
                 .double(createdAt.timeIntervalSince1970), .double(lastUsedAt.timeIntervalSince1970),
                 .int(sizeBytes), .int(pinned ? 1 : 0), .int(Int64(max(1, useCount))),
                 sourceApp.map(SQLValue.text) ?? .null])
            return (db.lastInsertRowid, false)
        }
    }

    /// Image counterpart of `importText`. See its semantics.
    @discardableResult
    public func importImage(data: Data, format: String, createdAt: Date, lastUsedAt: Date,
                            useCount: Int, pinned: Bool, sourceApp: String?) throws -> (id: Int64, merged: Bool)? {
        guard !data.isEmpty else { return nil }
        if Int64(data.count) > (try configInt64("image.max_size")) { return nil }
        let hash = ContentHasher.imageHash(data)
        let ext = format.lowercased()
        let relativePath = "\(hash).\(ext)"

        return try db.transaction {
            if let existing = try firstEntry("type = 'image' AND content_hash = ?", [.text(hash)]) {
                try mergeImported(into: existing.id, createdAt: createdAt,
                                  lastUsedAt: lastUsedAt, useCount: useCount, pinned: pinned)
                return (existing.id, true)
            }
            let fileURL = imagesDir.appendingPathComponent(relativePath)
            do {
                try data.write(to: fileURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: fileURL.path)
            } catch {
                throw ClapCoreError.io("failed to write image file at \(fileURL.path)")
            }
            do {
                try db.run("""
                    INSERT INTO entries (type, content, image_path, image_format, content_hash,
                                         created_at, last_used_at, size_bytes, is_pinned, use_count, source_app)
                    VALUES ('image', NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(relativePath), .text(ext), .text(hash),
                     .double(createdAt.timeIntervalSince1970), .double(lastUsedAt.timeIntervalSince1970),
                     .int(Int64(data.count)), .int(pinned ? 1 : 0), .int(Int64(max(1, useCount))),
                     sourceApp.map(SQLValue.text) ?? .null])
                return (db.lastInsertRowid, false)
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                throw error
            }
        }
    }

    /// Must run inside a transaction started by the caller.
    private func mergeImported(into id: Int64, createdAt: Date, lastUsedAt: Date,
                               useCount: Int, pinned: Bool) throws {
        try db.run("""
            UPDATE entries SET
                created_at   = MIN(created_at, ?),
                last_used_at = MAX(last_used_at, ?),
                use_count    = use_count + ?,
                is_pinned    = MAX(is_pinned, ?)
            WHERE id = ?
            """,
            [.double(createdAt.timeIntervalSince1970), .double(lastUsedAt.timeIntervalSince1970),
             .int(Int64(max(1, useCount))), .int(pinned ? 1 : 0), .int(id)])
    }

    // MARK: - Queries

    public func list(type: EntryType?, limit: Int, offset: Int) throws -> [ClipboardEntry] {
        try filteredList(SearchQuery(type: type, limit: limit, offset: offset))
    }

    public func search(_ query: SearchQuery) throws -> [ClipboardEntry] {
        if let pattern = query.regex {
            return try regexSearch(pattern, query: query)
        }
        if let text = query.text {
            let tokens = QueryTokenizer.tokenize(text)
            if !tokens.isEmpty {
                return try ftsSearch(tokens, query: query)
            }
        }
        return try filteredList(query)
    }

    public func entry(id: Int64) throws -> ClipboardEntry? {
        try firstEntry("id = ?", [.int(id)])
    }

    public func count(type: EntryType?) throws -> Int {
        if let type {
            return Int(try db.scalarInt64("SELECT COUNT(*) FROM entries WHERE type = ?",
                                          [.text(type.rawValue)]) ?? 0)
        }
        return Int(try db.scalarInt64("SELECT COUNT(*) FROM entries") ?? 0)
    }

    // MARK: - Mutations

    public func touch(id: Int64) throws {
        try db.run("UPDATE entries SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?",
                   [.double(Date().timeIntervalSince1970), .int(id)])
    }

    @discardableResult
    public func delete(id: Int64) throws -> Bool {
        guard let victim = try firstEntry("id = ?", [.int(id)]) else { return false }
        try db.run("DELETE FROM entries WHERE id = ?", [.int(id)])
        removeFiles(for: [victim])
        return true
    }

    /// Deletes the entry whose normalized text matches exactly (hash lookup).
    @discardableResult
    public func deleteMatching(text: String) throws -> Int {
        let normalized = TextNormalizer.normalize(text)
        guard !normalized.isEmpty else { return 0 }
        let hash = ContentHasher.textHash(normalized)
        try db.run("DELETE FROM entries WHERE type = 'text' AND content_hash = ?", [.text(hash)])
        return db.changes
    }

    /// Deletes all text entries whose content matches the regex.
    /// Batched candidate scan; all deletes in one transaction.
    @discardableResult
    public func deleteMatching(regexPattern: String) throws -> Int {
        let regex = try SafeRegex.compile(regexPattern)
        var victimIDs: [Int64] = []
        try scanTextEntries(pinnedOnly: false) { entry in
            if let content = entry.content, SafeRegex.matches(regex, in: content) {
                victimIDs.append(entry.id)
            }
            return true // keep scanning until the scan cap
        }
        guard !victimIDs.isEmpty else { return 0 }
        try db.transaction {
            for chunk in victimIDs.chunked(500) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.run("DELETE FROM entries WHERE id IN (\(placeholders))", chunk.map(SQLValue.int))
            }
        }
        return victimIDs.count
    }

    @discardableResult
    public func setPinned(_ pinned: Bool, id: Int64) throws -> Bool {
        try db.run("UPDATE entries SET is_pinned = ? WHERE id = ?", [.int(pinned ? 1 : 0), .int(id)])
        return db.changes > 0
    }

    /// Removes every entry (counters are kept) and wipes the contents of
    /// the images/ and thumbnails/ directories. Returns removed row count.
    @discardableResult
    public func clearAll() throws -> Int {
        let removed = try db.transaction {
            let count = Int(try db.scalarInt64("SELECT COUNT(*) FROM entries") ?? 0)
            try db.run("DELETE FROM entries")
            return count
        }
        let fm = FileManager.default
        for dir in [imagesDir, thumbnailsDir] {
            if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for url in contents { try? fm.removeItem(at: url) }
            }
        }
        // "Clear" must actually clear: without a checkpoint the deleted
        // clipboard text stays recoverable in the WAL until the next
        // maintenance pass.
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        return removed
    }

    // MARK: - Maintenance

    /// LRU eviction per category: enforce max_entries (count) and max_size
    /// (bytes). Pinned rows count toward usage but are never evicted.
    /// Returns total evicted count.
    @discardableResult
    public func enforceLimits() throws -> Int {
        var evicted = 0
        for type in EntryType.allCases {
            let maxEntries = try configInt("\(type.rawValue).max_entries")
            let maxSize = try configInt64("\(type.rawValue).max_size")
            var victims: [ClipboardEntry] = []

            try db.transaction {
                // Budgets apply to NON-PINNED rows only. If pinned rows were
                // counted, enough pinned entries would permanently starve
                // capture: every new unpinned entry would be evicted within
                // one maintenance cycle. Pinned entries live outside the
                // budget and are only ever removed explicitly.

                // Count limit: lowest last_used_at first.
                let total = Int(try db.scalarInt64(
                    "SELECT COUNT(*) FROM entries WHERE type = ? AND is_pinned = 0",
                    [.text(type.rawValue)]) ?? 0)
                if total > maxEntries {
                    let overflow = try db.query("""
                        SELECT \(Self.entryColumns) FROM entries
                        WHERE type = ? AND is_pinned = 0
                        ORDER BY last_used_at ASC, id ASC LIMIT ?
                        """,
                        [.text(type.rawValue), .int(Int64(total - maxEntries))], Self.rowToEntry)
                    try deleteRowsInCurrentTransaction(overflow)
                    victims += overflow
                }

                // Oversize entries first: an entry bigger than the whole
                // budget (possible after the user lowers max_size) must not
                // survive while LRU eviction destroys every older entry
                // chasing a cap it alone exceeds. Capture already rejects
                // oversize content, so this is rare.
                let oversize = try db.query("""
                    SELECT \(Self.entryColumns) FROM entries
                    WHERE type = ? AND is_pinned = 0 AND size_bytes > ?
                    """, [.text(type.rawValue), .int(maxSize)], Self.rowToEntry)
                if !oversize.isEmpty {
                    try deleteRowsInCurrentTransaction(oversize)
                    victims += oversize
                }

                // Byte limit over the remaining non-pinned rows. Fetched in
                // LRU-ordered batches — never all rows at once, which at 100k
                // entries would defeat the low-memory requirement.
                var usage = try db.scalarInt64(
                    "SELECT COALESCE(SUM(size_bytes), 0) FROM entries WHERE type = ? AND is_pinned = 0",
                    [.text(type.rawValue)]) ?? 0
                if usage > maxSize {
                    var byteVictims: [ClipboardEntry] = []
                    // Keyset pagination on (last_used_at, id) — must match the
                    // ORDER BY exactly or LRU rows get skipped.
                    var lastUsed = -Double.greatestFiniteMagnitude
                    var lastID: Int64 = 0
                    outer: while usage > maxSize {
                        let batch = try db.query("""
                            SELECT \(Self.entryColumns) FROM entries
                            WHERE type = ? AND is_pinned = 0
                              AND (last_used_at > ? OR (last_used_at = ? AND id > ?))
                            ORDER BY last_used_at ASC, id ASC LIMIT 500
                            """,
                            [.text(type.rawValue), .double(lastUsed), .double(lastUsed),
                             .int(lastID)], Self.rowToEntry)
                        if batch.isEmpty { break }
                        for candidate in batch {
                            guard usage > maxSize else { break outer }
                            byteVictims.append(candidate)
                            usage -= candidate.sizeBytes
                        }
                        if let last = batch.last {
                            lastUsed = last.lastUsedAt.timeIntervalSince1970
                            lastID = last.id
                        }
                    }
                    try deleteRowsInCurrentTransaction(byteVictims)
                    victims += byteVictims
                }
            }
            removeFiles(for: victims)
            evicted += victims.count
        }
        return evicted
    }

    /// Deletes non-pinned entries whose last_used_at is older than
    /// retention.days (0 = never). Returns deleted count.
    @discardableResult
    public func applyRetention() throws -> Int {
        let days = try configInt("retention.days")
        guard days > 0 else { return 0 }
        let cutoff = Date().timeIntervalSince1970 - Double(days) * 86_400
        // Batched: expired rows can be the majority of a 50MB corpus, and
        // their full content must never sit in memory at once.
        var removed = 0
        while true {
            let victims = try db.query("""
                SELECT \(Self.entryColumns) FROM entries
                WHERE is_pinned = 0 AND last_used_at < ? LIMIT 500
                """, [.double(cutoff)], Self.rowToEntry)
            guard !victims.isEmpty else { break }
            try db.transaction {
                try deleteRowsInCurrentTransaction(victims)
            }
            removeFiles(for: victims)
            removed += victims.count
        }
        return removed
    }

    /// WAL checkpoint (TRUNCATE) always; full VACUUM only when the freelist
    /// is large (> 1000 pages).
    public func vacuumIfNeeded() throws {
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let freelist = try db.scalarInt64("PRAGMA freelist_count") ?? 0
        if freelist > 1000 {
            try db.exec("VACUUM")
        }
    }

    // MARK: - Image helpers

    public func imageFileURL(for entry: ClipboardEntry) -> URL? {
        guard entry.type == .image, let path = entry.imagePath else { return nil }
        return imagesDir.appendingPathComponent(path)
    }

    /// Lazily generates thumbnails/<hash>.png (max 400 px long edge) via
    /// ImageIO. Returns nil for text entries.
    public func thumbnailURL(for entry: ClipboardEntry) throws -> URL? {
        guard entry.type == .image, let source = imageFileURL(for: entry) else { return nil }
        let thumbURL = thumbnailsDir.appendingPathComponent("\(entry.contentHash).png")
        if FileManager.default.fileExists(atPath: thumbURL.path) { return thumbURL }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ClapCoreError.io("image file missing at \(source.path)")
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ClapCoreError.io("unable to read image at \(source.path)")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw ClapCoreError.io("thumbnail generation failed for \(source.lastPathComponent)")
        }
        // Write via a same-directory temp file + rename: the app and the CLI
        // are separate processes sharing this directory, and a torn PNG at the
        // final path would be trusted forever by the fileExists check above.
        let tempURL = thumbnailsDir.appendingPathComponent(".\(entry.contentHash).\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ClapCoreError.io("unable to create thumbnail at \(thumbURL.path)")
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ClapCoreError.io("unable to finalize thumbnail at \(thumbURL.path)")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: tempURL.path)
        do {
            _ = try FileManager.default.replaceItemAt(thumbURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            // Lost a race with another process writing the same thumbnail.
            if !FileManager.default.fileExists(atPath: thumbURL.path) {
                throw ClapCoreError.io("unable to move thumbnail into place at \(thumbURL.path)")
            }
        }
        return thumbURL
    }

    // MARK: - Settings / stats / doctor

    static let configDefaults: [String: String] = [
        "text.max_entries": "100000",
        "text.max_size": "52428800",
        "image.max_entries": "500",
        "image.max_size": "104857600",
        "monitoring.paused": "0",
        "exclusions": "[]",
        "retention.days": "0",
        "launch_at_login": "0",
        // Synthesize Cmd+V into the frontmost app after copying from the UI
        // (Maccy-style). Requires Accessibility permission; falls back to
        // copy-only when not granted.
        "paste.on_copy": "1",
        // Shell history (zsh/bash) ingestion.
        "shell.enabled": "1",
        "shell.max_entries": "50000",
        "shell.max_size": "10485760",   // 10 MB
        "shell.histfile": "",           // empty = auto-detect
    ]

    /// Returns the stored value, falling back to the documented default when
    /// the key is a known config key, else nil.
    public func config(_ key: String) throws -> String? {
        if let stored = try db.scalarText("SELECT value FROM config WHERE key = ?", [.text(key)]) {
            return stored
        }
        return Self.configDefaults[key]
    }

    public func setConfig(_ key: String, value: String) throws {
        try db.run("""
            INSERT INTO config (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, [.text(key), .text(value)])
    }

    /// All config, with defaults merged in so every documented key appears.
    /// Sorted by key.
    public func allConfig() throws -> [(key: String, value: String)] {
        var merged = Self.configDefaults
        let stored = try db.query("SELECT key, value FROM config") {
            (key: $0.text(0) ?? "", value: $0.text(1) ?? "")
        }
        for row in stored { merged[row.key] = row.value }
        return merged.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
    }

    public func stats() throws -> StoreStats {
        var textCount = 0, imageCount = 0, shellCount = 0
        var textBytes: Int64 = 0, imageBytes: Int64 = 0, shellBytes: Int64 = 0
        _ = try db.query("SELECT type, COUNT(*), COALESCE(SUM(size_bytes), 0) FROM entries GROUP BY type") { stmt -> Void in
            switch stmt.text(0) {
            case "text":
                textCount = Int(stmt.int64(1)); textBytes = stmt.int64(2)
            case "image":
                imageCount = Int(stmt.int64(1)); imageBytes = stmt.int64(2)
            case "shell":
                shellCount = Int(stmt.int64(1)); shellBytes = stmt.int64(2)
            default:
                break
            }
        }
        let pinned = Int(try db.scalarInt64("SELECT COUNT(*) FROM entries WHERE is_pinned = 1") ?? 0)
        let day = Self.dayKey()
        let events = Int(try db.scalarInt64("SELECT value FROM stats_counters WHERE key = ?",
                                            [.text("events:\(day)")]) ?? 0)
        let dups = Int(try db.scalarInt64("SELECT value FROM stats_counters WHERE key = ?",
                                          [.text("dups:\(day)")]) ?? 0)
        let oldest = try db.scalarDouble("SELECT MIN(created_at) FROM entries")
            .map { Date(timeIntervalSince1970: $0) }
        return StoreStats(textCount: textCount, imageCount: imageCount, shellCount: shellCount,
                          textBytes: textBytes, imageBytes: imageBytes, shellBytes: shellBytes,
                          pinnedCount: pinned,
                          eventsToday: events, duplicatesAvoidedToday: dups,
                          oldestEntry: oldest)
    }

    public nonisolated static func doctorChecks(dataDir: URL?) -> [(name: String, ok: Bool, detail: String)] {
        var checks: [(name: String, ok: Bool, detail: String)] = []
        let fm = FileManager.default
        let dir = resolveDataDir(dataDir)

        // 1. Data dir exists and is writable.
        var isDir: ObjCBool = false
        let dirExists = fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
        let dirWritable = dirExists && fm.isWritableFile(atPath: dir.path)
        checks.append(("data directory", dirWritable,
                       dirExists ? (dirWritable ? dir.path : "not writable: \(dir.path)")
                                 : "missing: \(dir.path)"))

        // 2. Database opens.
        let dbPath = dir.appendingPathComponent("clap.sqlite").path
        var database: Database?
        if fm.fileExists(atPath: dbPath) {
            do {
                database = try Database(path: dbPath)
                checks.append(("database opens", true, dbPath))
            } catch {
                checks.append(("database opens", false, "\(error)"))
            }
        } else {
            checks.append(("database opens", false, "missing: \(dbPath)"))
        }

        // 3. Required tables exist.
        let requiredTables = ["entries", "entries_fts", "config", "stats_counters"]
        if let database {
            let found = (try? database.scalarInt64(
                "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('entries','entries_fts','config','stats_counters')"
            )) ?? 0
            let ok = found == Int64(requiredTables.count)
            checks.append(("required tables", ok,
                           ok ? requiredTables.joined(separator: ", ") : "found \(found) of \(requiredTables.count)"))
        } else {
            checks.append(("required tables", false, "database unavailable"))
        }

        // 4. Indexes exist.
        let requiredIndexes = ["idx_entries_hash", "idx_entries_lru", "idx_entries_type"]
        if let database {
            let found = (try? database.scalarInt64(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name IN ('idx_entries_hash','idx_entries_lru','idx_entries_type')"
            )) ?? 0
            let ok = found == Int64(requiredIndexes.count)
            checks.append(("indexes", ok, ok ? requiredIndexes.joined(separator: ", ")
                                             : "found \(found) of \(requiredIndexes.count)"))
        } else {
            checks.append(("indexes", false, "database unavailable"))
        }

        // 5. FTS5 available.
        let ftsAvailable: Bool = {
            guard let probe = try? Database(path: ":memory:") else { return false }
            return (try? probe.exec("CREATE VIRTUAL TABLE fts_probe USING fts5(x)")) != nil
        }()
        checks.append(("FTS5 available", ftsAvailable,
                       ftsAvailable ? "fts5 module present" : "fts5 module missing"))

        // 6. Images dir writable.
        let imagesPath = dir.appendingPathComponent("images", isDirectory: true).path
        var imagesIsDir: ObjCBool = false
        let imagesOK = fm.fileExists(atPath: imagesPath, isDirectory: &imagesIsDir)
            && imagesIsDir.boolValue && fm.isWritableFile(atPath: imagesPath)
        checks.append(("images directory", imagesOK, imagesOK ? imagesPath : "missing or not writable: \(imagesPath)"))

        // 7. Disk free space > 200MB.
        let probeURL = dirExists ? dir : fm.homeDirectoryForCurrentUser
        if let values = try? probeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            let ok = free > 200 * 1024 * 1024
            checks.append(("disk space", ok, "\(ByteSize.format(free)) free"))
        } else {
            checks.append(("disk space", false, "unable to determine free space"))
        }

        // 8. Shell history file.
        let shellHistfile: URL? = {
            if let custom = try? database?.scalarText("SELECT value FROM config WHERE key = 'shell.histfile'"),
               !custom.trimmingCharacters(in: .whitespaces).isEmpty {
                return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            }
            return ShellHistoryParser.defaultHistoryFile()
        }()
        if let shellHistfile {
            let readable = fm.isReadableFile(atPath: shellHistfile.path)
            checks.append(("shell history", readable, readable ? shellHistfile.path : "not readable: \(shellHistfile.path)"))
        } else {
            checks.append(("shell history", true, "no ~/.zsh_history or ~/.bash_history found (auto-detect)"))
        }

        return checks
    }

    // MARK: - Internal helpers

    static let entryColumns = "id, type, content, image_path, image_format, content_hash, created_at, last_used_at, size_bytes, is_pinned, use_count, source_app"

    static func rowToEntry(_ stmt: Statement) -> ClipboardEntry {
        ClipboardEntry(
            id: stmt.int64(0),
            type: EntryType(rawValue: stmt.text(1) ?? "") ?? .text,
            content: stmt.text(2),
            imagePath: stmt.text(3),
            imageFormat: stmt.text(4),
            contentHash: stmt.text(5) ?? "",
            createdAt: Date(timeIntervalSince1970: stmt.double(6)),
            lastUsedAt: Date(timeIntervalSince1970: stmt.double(7)),
            sizeBytes: stmt.int64(8),
            isPinned: stmt.int64(9) != 0,
            useCount: Int(stmt.int64(10)),
            sourceApp: stmt.text(11)
        )
    }

    private func firstEntry(_ whereClause: String, _ binds: [SQLValue]) throws -> ClipboardEntry? {
        try db.query("SELECT \(Self.entryColumns) FROM entries WHERE \(whereClause) LIMIT 1",
                     binds, Self.rowToEntry).first
    }

    private func incrementCounter(_ key: String) throws {
        try db.run("""
            INSERT INTO stats_counters (key, value) VALUES (?, 1)
            ON CONFLICT(key) DO UPDATE SET value = value + 1
            """, [.text(key)])
    }

    /// yyyy-MM-dd for the current day (local calendar).
    static func dayKey(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func configInt(_ key: String) throws -> Int {
        if let raw = try config(key), let value = Int(raw) { return value }
        return Int(Self.configDefaults[key] ?? "0") ?? 0
    }

    private func configInt64(_ key: String) throws -> Int64 {
        if let raw = try config(key), let value = Int64(raw) { return value }
        return Int64(Self.configDefaults[key] ?? "0") ?? 0
    }

    /// Deletes rows by id. Must already be inside a transaction.
    private func deleteRowsInCurrentTransaction(_ entries: [ClipboardEntry]) throws {
        guard !entries.isEmpty else { return }
        for chunk in entries.map(\.id).chunked(500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.run("DELETE FROM entries WHERE id IN (\(placeholders))", chunk.map(SQLValue.int))
        }
    }

    /// Removes image + thumbnail files for evicted/deleted image entries.
    private func removeFiles(for entries: [ClipboardEntry]) {
        let fm = FileManager.default
        for entry in entries where entry.type == .image {
            if let path = entry.imagePath {
                try? fm.removeItem(at: imagesDir.appendingPathComponent(path))
            }
            try? fm.removeItem(at: thumbnailsDir.appendingPathComponent("\(entry.contentHash).png"))
        }
    }

    // MARK: - Search internals

    /// `type IN (…)` fragment + binds for the query's effective type filter.
    private static func typeFilter(_ query: SearchQuery,
                                   column: String = "type") -> (sql: String, binds: [SQLValue])? {
        guard let types = query.effectiveTypes, !types.isEmpty else { return nil }
        let placeholders = Array(repeating: "?", count: types.count).joined(separator: ", ")
        let binds = types.map { SQLValue.text($0.rawValue) }.sorted { lhs, rhs in
            if case let .text(l) = lhs, case let .text(r) = rhs { return l < r }
            return false
        }
        return ("\(column) IN (\(placeholders))", binds)
    }

    private func filteredList(_ query: SearchQuery) throws -> [ClipboardEntry] {
        var conditions: [String] = []
        var binds: [SQLValue] = []
        if let filter = Self.typeFilter(query) {
            conditions.append(filter.sql)
            binds.append(contentsOf: filter.binds)
        }
        if query.pinnedOnly { conditions.append("is_pinned = 1") }
        var sql = "SELECT \(Self.entryColumns) FROM entries"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY last_used_at DESC, id DESC LIMIT ? OFFSET ?"
        binds.append(.int(Int64(max(0, query.limit))))
        binds.append(.int(Int64(max(0, query.offset))))
        return try db.query(sql, binds, Self.rowToEntry)
    }

    /// Builds an FTS5 MATCH expression: bare terms become `"term"*` (prefix)
    /// AND-joined; quoted phrases stay phrases. Double quotes are escaped.
    static func ftsMatchExpression(_ tokens: [QueryTokenizer.Token]) -> String {
        tokens.map { token in
            let escaped = token.value.replacingOccurrences(of: "\"", with: "\"\"")
            return token.quoted ? "\"\(escaped)\"" : "\"\(escaped)\"*"
        }.joined(separator: " ")
    }

    private func ftsSearch(_ tokens: [QueryTokenizer.Token], query: SearchQuery) throws -> [ClipboardEntry] {
        let match = Self.ftsMatchExpression(tokens)
        let prefixedColumns = Self.entryColumns
            .split(separator: ",")
            .map { "e.\($0.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: ", ")
        var sql = """
            SELECT \(prefixedColumns) FROM entries e
            JOIN entries_fts ON entries_fts.rowid = e.id
            WHERE entries_fts MATCH ?
            """
        var binds: [SQLValue] = [.text(match)]
        if let filter = Self.typeFilter(query, column: "e.type") {
            sql += " AND \(filter.sql)"
            binds.append(contentsOf: filter.binds)
        }
        if query.pinnedOnly { sql += " AND e.is_pinned = 1" }
        sql += " ORDER BY e.last_used_at DESC, e.id DESC LIMIT ? OFFSET ?"
        binds.append(.int(Int64(max(0, query.limit))))
        binds.append(.int(Int64(max(0, query.offset))))
        return try db.query(sql, binds, Self.rowToEntry)
    }

    static let regexScanCap = 20_000
    static let regexScanBatchSize = 500
    /// Wall-clock budget for a whole regex scan. Length caps alone don't
    /// bound catastrophic backtracking; without this a pathological pattern
    /// could stall the store actor (and with it, clipboard capture).
    static let regexScanTimeBudget: TimeInterval = 2.0

    /// Batched candidate scan over text entries in last_used_at DESC order.
    /// Calls `visit` per row; stops when `visit` returns false, the scan cap
    /// is reached, or the time budget is exhausted (partial results).
    private func scanTextEntries(pinnedOnly: Bool, contentType: EntryType? = nil,
                                 _ visit: (ClipboardEntry) throws -> Bool) throws {
        var scanned = 0
        var dbOffset = 0
        let deadline = Date().addingTimeInterval(Self.regexScanTimeBudget)
        while scanned < Self.regexScanCap {
            if Date() >= deadline { return }
            // Regex scans every content-bearing type (text + shell).
            var sql = "SELECT \(Self.entryColumns) FROM entries WHERE type IN ('text', 'shell')"
            if let only = contentType { sql += " AND type = '\(only.rawValue)'" }
            if pinnedOnly { sql += " AND is_pinned = 1" }
            sql += " ORDER BY last_used_at DESC, id DESC LIMIT ? OFFSET ?"
            let batch = try db.query(sql, [.int(Int64(Self.regexScanBatchSize)), .int(Int64(dbOffset))],
                                     Self.rowToEntry)
            if batch.isEmpty { return }
            for entry in batch {
                scanned += 1
                if try !visit(entry) { return }
                if scanned >= Self.regexScanCap { return }
                if Date() >= deadline { return }
            }
            dbOffset += batch.count
            if batch.count < Self.regexScanBatchSize { return }
        }
    }

    private func regexSearch(_ pattern: String, query: SearchQuery) throws -> [ClipboardEntry] {
        // Regex applies to content-bearing entries only (text and shell).
        let allowed = (query.effectiveTypes ?? [.text, .shell]).subtracting([.image])
        if allowed.isEmpty { return [] }
        let single = allowed.count == 1 ? allowed.first : nil
        let regex = try SafeRegex.compile(pattern)
        var results: [ClipboardEntry] = []
        var toSkip = max(0, query.offset)
        let limit = max(0, query.limit)
        guard limit > 0 else { return [] }
        try scanTextEntries(pinnedOnly: query.pinnedOnly, contentType: single) { entry in
            if let content = entry.content, SafeRegex.matches(regex, in: content) {
                if toSkip > 0 {
                    toSkip -= 1
                } else {
                    results.append(entry)
                    if results.count >= limit { return false }
                }
            }
            return true
        }
        return results
    }

    // MARK: - Test hooks (internal)

    /// Backdates timestamps for deterministic ordering/retention tests.
    func _test_setTimestamps(id: Int64, createdAt: Date? = nil, lastUsedAt: Date? = nil) throws {
        if let createdAt {
            try db.run("UPDATE entries SET created_at = ? WHERE id = ?",
                       [.double(createdAt.timeIntervalSince1970), .int(id)])
        }
        if let lastUsedAt {
            try db.run("UPDATE entries SET last_used_at = ? WHERE id = ?",
                       [.double(lastUsedAt.timeIntervalSince1970), .int(id)])
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
