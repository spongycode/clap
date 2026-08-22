import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Maintenance: LRU eviction, retention, vacuum, image files

extension ClipboardStore {

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
                    "SELECT COUNT(*) FROM entries WHERE type = ? AND is_pinned = 0 AND is_favorite = 0",
                    [.text(type.rawValue)]) ?? 0)
                if total > maxEntries {
                    let overflow = try db.query("""
                        SELECT \(Self.entryColumns) FROM entries
                        WHERE type = ? AND is_pinned = 0 AND is_favorite = 0
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
                    WHERE type = ? AND is_pinned = 0 AND is_favorite = 0 AND size_bytes > ?
                    """, [.text(type.rawValue), .int(maxSize)], Self.rowToEntry)
                if !oversize.isEmpty {
                    try deleteRowsInCurrentTransaction(oversize)
                    victims += oversize
                }

                victims += try evictByteOverage(type: type, maxSize: maxSize)
            }
            removeFiles(for: victims)
            evicted += victims.count
        }
        return evicted
    }

    /// Byte limit over the remaining non-pinned, non-favorite rows. Fetched in
    /// LRU-ordered batches — never all rows at once, which at 100k entries
    /// would defeat the low-memory requirement. Must run inside a transaction.
    private func evictByteOverage(type: EntryType, maxSize: Int64) throws -> [ClipboardEntry] {
        var usage = try db.scalarInt64(
            "SELECT COALESCE(SUM(size_bytes), 0) FROM entries WHERE type = ? AND is_pinned = 0 AND is_favorite = 0",
            [.text(type.rawValue)]) ?? 0
        guard usage > maxSize else { return [] }
        var byteVictims: [ClipboardEntry] = []
        // Keyset pagination on (last_used_at, id) — must match the ORDER BY
        // exactly or LRU rows get skipped.
        var lastUsed = -Double.greatestFiniteMagnitude
        var lastID: Int64 = 0
        outer: while usage > maxSize {
            let batch = try db.query("""
                SELECT \(Self.entryColumns) FROM entries
                WHERE type = ? AND is_pinned = 0 AND is_favorite = 0
                  AND (last_used_at > ? OR (last_used_at = ? AND id > ?))
                ORDER BY last_used_at ASC, id ASC LIMIT \(CoreConstants.sqlBatchSize)
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
        return byteVictims
    }

    /// Deletes non-pinned entries whose last_used_at is older than
    /// retention.days (0 = never). Returns deleted count.
    @discardableResult
    public func applyRetention() throws -> Int {
        let days = try configInt(ConfigKey.retentionDays)
        guard days > 0 else { return 0 }
        let cutoff = clock().timeIntervalSince1970 - Double(days) * CoreConstants.secondsPerDay
        // Batched: expired rows can be the majority of a 50MB corpus, and
        // their full content must never sit in memory at once.
        var removed = 0
        while true {
            let victims = try db.query("""
                SELECT \(Self.entryColumns) FROM entries
                WHERE is_pinned = 0 AND is_favorite = 0 AND last_used_at < ? LIMIT \(CoreConstants.sqlBatchSize)
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
    /// is large.
    public func vacuumIfNeeded() throws {
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let freelist = try db.scalarInt64("PRAGMA freelist_count") ?? 0
        if freelist > CoreConstants.vacuumFreelistPageThreshold {
            try db.exec("VACUUM")
        }
    }

    // MARK: - Image helpers

    public func imageFileURL(for entry: ClipboardEntry) -> URL? {
        guard entry.type == .image, let path = entry.imagePath else { return nil }
        return dataDir.appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(path)
    }

    /// Lazily generates thumbnails/<hash>.png (max edge from constants) via
    /// ImageIO. Returns nil for text entries.
    public func thumbnailURL(for entry: ClipboardEntry) throws -> URL? {
        guard entry.type == .image, let source = imageFileURL(for: entry) else { return nil }
        let thumbsDir = dataDir.appendingPathComponent("thumbnails", isDirectory: true)
        let thumbURL = thumbsDir.appendingPathComponent("\(entry.contentHash).png")
        if FileManager.default.fileExists(atPath: thumbURL.path) { return thumbURL }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ClapCoreError.io("image file missing at \(source.path)")
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ClapCoreError.io("unable to read image at \(source.path)")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: CoreConstants.thumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw ClapCoreError.io("thumbnail generation failed for \(source.lastPathComponent)")
        }
        // Write via a same-directory temp file + rename: the app and the CLI
        // are separate processes sharing this directory, and a torn PNG at the
        // final path would be trusted forever by the fileExists check above.
        let tempURL = thumbsDir.appendingPathComponent(".\(entry.contentHash).\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ClapCoreError.io("unable to create thumbnail at \(thumbURL.path)")
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            removeTempFile(tempURL)
            throw ClapCoreError.io("unable to finalize thumbnail at \(thumbURL.path)")
        }
        try? FileManager.default.setAttributes(CoreConstants.ownerOnlyFileAttributes,
                                               ofItemAtPath: tempURL.path)
        do {
            _ = try FileManager.default.replaceItemAt(thumbURL, withItemAt: tempURL)
        } catch {
            removeTempFile(tempURL)
            // Lost a race with another process writing the same thumbnail.
            if !FileManager.default.fileExists(atPath: thumbURL.path) {
                throw ClapCoreError.io("unable to move thumbnail into place at \(thumbURL.path)")
            }
        }
        return thumbURL
    }

    private func removeTempFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Self.logger.error("temp cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
