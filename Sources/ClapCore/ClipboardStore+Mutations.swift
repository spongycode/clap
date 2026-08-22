import Foundation

// MARK: - Mutations: touch, delete, pin/favorite, shortcuts, tags, clear

extension ClipboardStore {

    public func touch(id: Int64) throws {
        try touchRow(id: id, at: clock().timeIntervalSince1970)
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

    /// Deletes all content-bearing entries whose content matches the regex.
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
        var victims: [ClipboardEntry] = []
        try db.transaction {
            victims = try fetchEntries(ids: victimIDs)
            try deleteRowsInCurrentTransaction(victims)
        }
        removeFiles(for: victims)
        return victims.count
    }

    private func fetchEntries(ids: [Int64]) throws -> [ClipboardEntry] {
        var result: [ClipboardEntry] = []
        for chunk in ids.chunked(CoreConstants.sqlBatchSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            result += try db.query(
                "SELECT \(Self.entryColumns) FROM entries WHERE id IN (\(placeholders))",
                chunk.map(SQLValue.int), Self.rowToEntry)
        }
        return result
    }

    @discardableResult
    public func setPinned(_ pinned: Bool, id: Int64) throws -> Bool {
        try db.run("UPDATE entries SET is_pinned = ? WHERE id = ?", [.int(pinned ? 1 : 0), .int(id)])
        return db.changes > 0
    }

    @discardableResult
    public func setFavorite(_ favorite: Bool, id: Int64) throws -> Bool {
        try db.run("UPDATE entries SET is_favorite = ? WHERE id = ?", [.int(favorite ? 1 : 0), .int(id)])
        return db.changes > 0
    }

    /// Sets or removes a trigger shortcut (e.g. ";email") for an entry.
    @discardableResult
    public func setShortcut(_ shortcut: String?, id: Int64) throws -> Bool {
        let trimmed = shortcut?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
        try db.run("UPDATE entries SET shortcut = ? WHERE id = ?",
                   [normalized.map(SQLValue.text) ?? .null, .int(id)])
        return db.changes > 0
    }

    /// Returns a dictionary of all active shortcuts mapping `shortcut -> expandedText`.
    public func allShortcuts() throws -> [String: String] {
        let rows = try db.query("""
            SELECT shortcut, content FROM entries
            WHERE shortcut IS NOT NULL AND shortcut != '' AND content IS NOT NULL AND content != ''
            """, [], { stmt in
            (stmt.text(0) ?? "", stmt.text(1) ?? "")
        })
        var map: [String: String] = [:]
        for (shortcut, content) in rows where !shortcut.isEmpty && !content.isEmpty {
            map[shortcut] = content
        }
        return map
    }

    // MARK: - Tags / Pinboards

    /// Adds a tag to an entry (e.g. "code", "work"). Strips leading '#' and whitespace.
    @discardableResult
    public func addTag(_ rawTag: String, entryID: Int64) throws -> Bool {
        guard let tag = Self.normalizeTag(rawTag) else { return false }
        try db.run("""
            INSERT OR IGNORE INTO entry_tags (entry_id, tag, created_at)
            VALUES (?, ?, ?)
            """, [.int(entryID), .text(tag), .double(clock().timeIntervalSince1970)])
        return db.changes > 0
    }

    /// Removes a tag from an entry.
    @discardableResult
    public func removeTag(_ rawTag: String, entryID: Int64) throws -> Bool {
        guard let tag = Self.normalizeTag(rawTag) else { return false }
        try db.run("DELETE FROM entry_tags WHERE entry_id = ? AND tag = ? COLLATE NOCASE",
                   [.int(entryID), .text(tag)])
        return db.changes > 0
    }

    /// Sets the full list of tags for an entry, replacing any previous tags.
    public func setTags(_ tags: [String], entryID: Int64) throws {
        var seen = Set<String>()
        var unique: [String] = []
        for rawTag in tags {
            guard let tag = Self.normalizeTag(rawTag), !seen.contains(tag) else { continue }
            seen.insert(tag)
            unique.append(tag)
        }
        let now = clock().timeIntervalSince1970
        try db.transaction {
            try db.run("DELETE FROM entry_tags WHERE entry_id = ?", [.int(entryID)])
            for t in unique {
                try db.run("INSERT OR IGNORE INTO entry_tags (entry_id, tag, created_at) VALUES (?, ?, ?)",
                           [.int(entryID), .text(t), .double(now)])
            }
        }
    }

    /// Returns all tags for a specific entry.
    public func tags(for entryID: Int64) throws -> [String] {
        try db.query("SELECT tag FROM entry_tags WHERE entry_id = ? ORDER BY tag COLLATE NOCASE ASC",
                     [.int(entryID)]) { $0.text(0) ?? "" }
    }

    /// Returns all distinct tags across the store with their respective entry counts.
    public func allTags() throws -> [(tag: String, count: Int)] {
        try db.query("""
            SELECT tag, COUNT(*) as count FROM entry_tags
            GROUP BY tag COLLATE NOCASE
            ORDER BY tag COLLATE NOCASE ASC
            """) { stmt in
            (tag: stmt.text(0) ?? "", count: Int(stmt.int64(1)))
        }
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
        wipeDirectoryContents(imagesDirectory)
        wipeDirectoryContents(thumbnailsDirectory)
        // "Clear" must actually clear: without a checkpoint the deleted
        // clipboard text stays recoverable in the WAL until the next
        // maintenance pass.
        do {
            try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        } catch {
            Self.logger.error("post-clear WAL checkpoint failed: \(error.localizedDescription, privacy: .public)")
        }
        return removed
    }

    private func wipeDirectoryContents(_ dir: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            Self.logger.error("clear could not list \(dir.lastPathComponent, privacy: .public)")
            return
        }
        for url in contents {
            do {
                try fm.removeItem(at: url)
            } catch {
                Self.logger.error("wipe failed in \(dir.lastPathComponent, privacy: .public): \(error.localizedDescription)")
            }
        }
    }
}
