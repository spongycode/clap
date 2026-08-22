import Foundation

// MARK: - Capture, shell ingestion and import
//
// All inserts go through insertEntry; all duplicate touches through touchRow.
// OCR runs OUTSIDE the write transaction: accurate-mode recognition can take
// hundreds of milliseconds, and holding the IMMEDIATE lock that long would
// stall the other process sharing the database.

extension ClipboardStore {

    @discardableResult
    public func captureText(_ raw: String, sourceApp: String?) throws -> (entry: ClipboardEntry, wasDuplicate: Bool)? {
        let normalized = TextNormalizer.normalize(raw)
        guard !normalized.isEmpty else { return nil }
        // A single entry larger than the whole category budget must never be
        // stored: byte eviction would otherwise delete every older unpinned
        // entry chasing a cap this entry alone exceeds.
        let sizeBytes = Int64(normalized.utf8.count)
        if sizeBytes > (try configInt64(ConfigKey.textMaxSize)) { return nil }
        let hash = ContentHasher.textHash(normalized)
        let timestamp = clock().timeIntervalSince1970
        let day = Self.dayKey(clock())

        return try db.transaction {
            try incrementCounter("events:\(day)")
            // content equality guards against a (rare) 64-bit hash collision
            // silently discarding unrelated text as a "duplicate".
            if let existing = try firstEntry("type = 'text' AND content_hash = ? AND content = ?",
                                             [.text(hash), .text(normalized)]) {
                try touchRow(id: existing.id, at: timestamp)
                try incrementCounter("dups:\(day)")
                guard let updated = try firstEntry("id = ?", [.int(existing.id)]) else {
                    throw ClapCoreError.database(code: 0, message: "entry vanished during capture")
                }
                return (updated, true)
            }
            let id = try insertEntry(type: .text, content: normalized, imagePath: nil, imageFormat: nil,
                                     hash: hash, createdAt: timestamp, lastUsedAt: timestamp,
                                     sizeBytes: sizeBytes, pinned: false, useCount: 1, sourceApp: sourceApp)
            guard let inserted = try firstEntry("id = ?", [.int(id)]) else {
                throw ClapCoreError.database(code: 0, message: "insert did not produce a row")
            }
            return (inserted, false)
        }
    }

    @discardableResult
    public func captureImage(data: Data, format: String, sourceApp: String?) async throws -> (entry: ClipboardEntry, wasDuplicate: Bool)? {
        guard !data.isEmpty else { return nil }
        if Int64(data.count) > (try configInt64(ConfigKey.imageMaxSize)) { return nil }
        let hash = ContentHasher.imageHash(data)
        let ext = format.lowercased()
        let relativePath = "\(hash).\(ext)"
        let timestamp = clock().timeIntervalSince1970
        let day = Self.dayKey(clock())
        let ocrText = await ocr.recognizeText(from: data)

        return try db.transaction {
            try incrementCounter("events:\(day)")
            if let existing = try firstEntry("type = 'image' AND content_hash = ?", [.text(hash)]) {
                // Duplicate image: touch only, never rewrite the file.
                try touchRow(id: existing.id, at: timestamp)
                try incrementCounter("dups:\(day)")
                guard let updated = try firstEntry("id = ?", [.int(existing.id)]) else {
                    throw ClapCoreError.database(code: 0, message: "entry vanished during capture")
                }
                return (updated, true)
            }
            let id = try storeNewImage(data: data, relativePath: relativePath, imageFormat: ext,
                                       ocrText: ocrText, hash: hash,
                                       createdAt: timestamp, lastUsedAt: timestamp,
                                       pinned: false, useCount: 1, sourceApp: sourceApp)
            guard let inserted = try firstEntry("id = ?", [.int(id)]) else {
                throw ClapCoreError.database(code: 0, message: "insert did not produce a row")
            }
            return (inserted, false)
        }
    }

    /// Ingests one executed shell command (live watcher and backfill both use
    /// this). Dedup merges: re-running a command bumps recency and use_count
    /// instead of inserting a new row. Daily clipboard counters are NOT
    /// touched — commands aren't clipboard events. Returns nil when empty or
    /// oversize.
    @discardableResult
    public func ingestShell(_ command: String, executedAt: Date?,
                            source: String? = nil) throws -> (id: Int64, merged: Bool)? {
        guard let prepared = prepareShell(command) else { return nil }
        let when = executedAt ?? clock()
        return try db.transaction {
            try upsertShellInCurrentTransaction(prepared, when: when, source: source)
        }
    }

    /// Ingests a batch of shell commands within a single database transaction.
    @discardableResult
    public func ingestShellBatch(_ commands: [(text: String, executedAt: Date?)],
                                 source: String? = nil) throws -> (imported: Int, merged: Int) {
        guard !commands.isEmpty else { return (0, 0) }
        var imported = 0
        var merged = 0
        try db.transaction {
            for item in commands {
                guard let prepared = prepareShell(item.text) else { continue }
                let when = item.executedAt ?? clock()
                let (_, didMerge) = try upsertShellInCurrentTransaction(prepared, when: when, source: source)
                if didMerge { merged += 1 } else { imported += 1 }
            }
        }
        return (imported, merged)
    }

    private func prepareShell(_ command: String) -> (normalized: String, hash: String, sizeBytes: Int64)? {
        let normalized = TextNormalizer.normalize(command)
        guard !normalized.isEmpty else { return nil }
        let sizeBytes = Int64(normalized.utf8.count)
        guard sizeBytes <= maxShellSize else { return nil }
        return (normalized, ContentHasher.textHash(normalized), sizeBytes)
    }

    private var maxShellSize: Int64 {
        (try? configInt64(ConfigKey.shellMaxSize)) ?? 10_485_760
    }

    /// Shared merge-or-insert pipeline for both ingest entry points.
    /// Must run inside a transaction started by the caller.
    private func upsertShellInCurrentTransaction(_ prepared: (normalized: String, hash: String, sizeBytes: Int64),
                                                 when: Date, source: String?) throws -> (id: Int64, merged: Bool) {
        let timestamp = when.timeIntervalSince1970
        if let existing = try firstEntry("type = 'shell' AND content_hash = ? AND content = ?",
                                         [.text(prepared.hash), .text(prepared.normalized)]) {
            try db.run("""
                UPDATE entries SET
                    created_at   = MIN(created_at, ?),
                    last_used_at = MAX(last_used_at, ?),
                    use_count    = use_count + 1
                WHERE id = ?
                """,
                [.double(timestamp), .double(timestamp), .int(existing.id)])
            return (existing.id, true)
        }
        let id = try insertEntry(type: .shell, content: prepared.normalized, imagePath: nil, imageFormat: nil,
                                 hash: prepared.hash, createdAt: timestamp, lastUsedAt: timestamp,
                                 sizeBytes: prepared.sizeBytes, pinned: false, useCount: 1, sourceApp: source)
        return (id, false)
    }

    // MARK: - Import

    /// Imports a text entry from another clipboard manager, preserving its
    /// history metadata. Unlike capture, this does not bump daily counters
    /// (imported rows are not today's clipboard events). Duplicates merge:
    /// earliest created_at, latest last_used_at, summed use_count, pin wins.
    /// Returns nil when the text is empty after normalization or oversize.
    @discardableResult
    public func importText(_ raw: String, createdAt: Date, lastUsedAt: Date,
                           useCount: Int, pinned: Bool, sourceApp: String?) async throws -> (id: Int64, merged: Bool)? {
        let normalized = TextNormalizer.normalize(raw)
        guard !normalized.isEmpty else { return nil }
        let sizeBytes = Int64(normalized.utf8.count)
        if sizeBytes > (try configInt64(ConfigKey.textMaxSize)) { return nil }
        let hash = ContentHasher.textHash(normalized)

        return try db.transaction {
            if let existing = try firstEntry("type = 'text' AND content_hash = ? AND content = ?",
                                             [.text(hash), .text(normalized)]) {
                try mergeImported(into: existing.id, createdAt: createdAt,
                                  lastUsedAt: lastUsedAt, useCount: useCount, pinned: pinned)
                return (existing.id, true)
            }
            let id = try insertEntry(type: .text, content: normalized, imagePath: nil, imageFormat: nil,
                                     hash: hash, createdAt: createdAt.timeIntervalSince1970,
                                     lastUsedAt: lastUsedAt.timeIntervalSince1970,
                                     sizeBytes: sizeBytes, pinned: pinned, useCount: useCount,
                                     sourceApp: sourceApp)
            return (id, false)
        }
    }

    /// Image counterpart of `importText`. See its semantics.
    @discardableResult
    public func importImage(data: Data, format: String, createdAt: Date, lastUsedAt: Date,
                            useCount: Int, pinned: Bool, sourceApp: String?) async throws -> (id: Int64, merged: Bool)? {
        guard !data.isEmpty else { return nil }
        if Int64(data.count) > (try configInt64(ConfigKey.imageMaxSize)) { return nil }
        let hash = ContentHasher.imageHash(data)
        let ext = format.lowercased()
        let relativePath = "\(hash).\(ext)"
        let ocrText = await ocr.recognizeText(from: data)

        return try db.transaction {
            if let existing = try firstEntry("type = 'image' AND content_hash = ?", [.text(hash)]) {
                try mergeImported(into: existing.id, createdAt: createdAt,
                                  lastUsedAt: lastUsedAt, useCount: useCount, pinned: pinned)
                return (existing.id, true)
            }
            let id = try storeNewImage(data: data, relativePath: relativePath, imageFormat: ext,
                                       ocrText: ocrText, hash: hash,
                                       createdAt: createdAt.timeIntervalSince1970,
                                       lastUsedAt: lastUsedAt.timeIntervalSince1970,
                                       pinned: pinned, useCount: useCount, sourceApp: sourceApp)
            return (id, false)
        }
    }

    /// Writes original bytes atomically, then inserts the row. If the insert
    /// fails the row rolls back with the transaction and the file must not be
    /// left orphaned on disk.
    private func storeNewImage(data: Data, relativePath: String, imageFormat: String, ocrText: String?,
                               hash: String, createdAt: Double, lastUsedAt: Double,
                               pinned: Bool, useCount: Int, sourceApp: String?) throws -> Int64 {
        let fileURL = imagesDirectory.appendingPathComponent(relativePath)
        do {
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(CoreConstants.ownerOnlyFileAttributes,
                                                   ofItemAtPath: fileURL.path)
        } catch {
            Self.logger.error("image file write failed: \(error.localizedDescription, privacy: .public)")
            throw ClapCoreError.io("failed to write image file at \(fileURL.path)")
        }
        do {
            return try insertEntry(type: .image, content: ocrText, imagePath: relativePath,
                                   imageFormat: imageFormat, hash: hash, createdAt: createdAt,
                                   lastUsedAt: lastUsedAt, sizeBytes: Int64(data.count),
                                   pinned: pinned, useCount: useCount, sourceApp: sourceApp)
        } catch {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                Self.logger.error("orphan image cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    /// Updates the extracted OCR text for an image entry.
    public func updateOCRText(for entryID: Int64, ocrText: String) throws {
        try db.run("UPDATE entries SET content = ? WHERE id = ? AND type = 'image'",
                   [.text(ocrText), .int(entryID)])
    }

    /// Must run inside a transaction started by the caller.
    func mergeImported(into id: Int64, createdAt: Date, lastUsedAt: Date,
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
}
