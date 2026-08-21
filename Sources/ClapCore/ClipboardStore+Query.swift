import Foundation

// MARK: - Queries: list, FTS search, regex search

extension ClipboardStore {

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

    // MARK: - Search internals

    /// `type IN (…)` fragment + binds for the query's effective type filter.
    static func typeFilter(_ query: SearchQuery,
                           column: String = "type") -> (sql: String, binds: [SQLValue])? {
        guard let types = query.effectiveTypes, !types.isEmpty else { return nil }
        let placeholders = Array(repeating: "?", count: types.count).joined(separator: ", ")
        return ("\(column) IN (\(placeholders))", types.map { SQLValue.text($0.rawValue) })
    }

    func filteredList(_ query: SearchQuery) throws -> [ClipboardEntry] {
        var conditions: [String] = []
        var binds: [SQLValue] = []
        if let filter = Self.typeFilter(query) {
            conditions.append(filter.sql)
            binds.append(contentsOf: filter.binds)
        }
        if query.pinnedOnly { conditions.append("is_pinned = 1") }
        if query.favoriteOnly { conditions.append("is_favorite = 1") }
        if let tag = Self.normalizeTag(query.tag ?? "") {
            conditions.append("id IN (SELECT entry_id FROM entry_tags WHERE tag = ? COLLATE NOCASE)")
            binds.append(.text(tag))
        }
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

    func ftsSearch(_ tokens: [QueryTokenizer.Token], query: SearchQuery) throws -> [ClipboardEntry] {
        let match = Self.ftsMatchExpression(tokens)
        var sql = """
            SELECT \(Self.prefixedEntryColumns) FROM entries e
            JOIN entries_fts ON entries_fts.rowid = e.id
            WHERE entries_fts MATCH ?
            """
        var binds: [SQLValue] = [.text(match)]
        if let filter = Self.typeFilter(query, column: "e.type") {
            sql += " AND \(filter.sql)"
            binds.append(contentsOf: filter.binds)
        }
        if query.pinnedOnly { sql += " AND e.is_pinned = 1" }
        if query.favoriteOnly { sql += " AND e.is_favorite = 1" }
        if let tag = Self.normalizeTag(query.tag ?? "") {
            sql += " AND e.id IN (SELECT entry_id FROM entry_tags WHERE tag = ? COLLATE NOCASE)"
            binds.append(.text(tag))
        }
        sql += " ORDER BY e.last_used_at DESC, e.id DESC LIMIT ? OFFSET ?"
        binds.append(.int(Int64(max(0, query.limit))))
        binds.append(.int(Int64(max(0, query.offset))))
        return try db.query(sql, binds, Self.rowToEntry)
    }

    static let regexScanCap = 20_000
    /// Wall-clock budget for a whole regex scan. Length caps alone don't
    /// bound catastrophic backtracking; without this a pathological pattern
    /// could stall the store actor (and with it, clipboard capture).
    static let regexScanTimeBudget: TimeInterval = 2.0

    /// Batched candidate scan over content-bearing entries in last_used_at
    /// DESC order. Calls `visit` per row; stops when `visit` returns false,
    /// the scan cap is reached, or the time budget is exhausted (partial
    /// results).
    func scanTextEntries(pinnedOnly: Bool, favoriteOnly: Bool = false, tag: String? = nil,
                         contentType: EntryType? = nil,
                         _ visit: (ClipboardEntry) throws -> Bool) throws {
        var scanned = 0
        var dbOffset = 0
        let deadline = clock().addingTimeInterval(Self.regexScanTimeBudget)
        let cleanedTag = Self.normalizeTag(tag ?? "")
        while scanned < Self.regexScanCap {
            if clock() >= deadline { return }
            // Regex scans every content-bearing type (text + shell).
            var sql = "SELECT \(Self.entryColumns) FROM entries WHERE type IN ('text', 'shell')"
            var binds: [SQLValue] = []
            if let only = contentType {
                sql += " AND type = ?"
                binds.append(.text(only.rawValue))
            }
            if pinnedOnly { sql += " AND is_pinned = 1" }
            if favoriteOnly { sql += " AND is_favorite = 1" }
            if let cleanedTag {
                sql += " AND id IN (SELECT entry_id FROM entry_tags WHERE tag = ? COLLATE NOCASE)"
                binds.append(.text(cleanedTag))
            }
            sql += " ORDER BY last_used_at DESC, id DESC LIMIT ? OFFSET ?"
            binds.append(.int(Int64(CoreConstants.sqlBatchSize)))
            binds.append(.int(Int64(dbOffset)))
            let batch = try db.query(sql, binds, Self.rowToEntry)
            if batch.isEmpty { return }
            for entry in batch {
                scanned += 1
                if try !visit(entry) { return }
                if scanned >= Self.regexScanCap { return }
                if clock() >= deadline { return }
            }
            dbOffset += batch.count
            if batch.count < CoreConstants.sqlBatchSize { return }
        }
    }

    func regexSearch(_ pattern: String, query: SearchQuery) throws -> [ClipboardEntry] {
        // Regex applies to content-bearing entries only (text and shell).
        let allowed = (query.effectiveTypes ?? [.text, .shell]).subtracting([.image])
        if allowed.isEmpty { return [] }
        let single = allowed.count == 1 ? allowed.first : nil
        let regex = try SafeRegex.compile(pattern)
        var results: [ClipboardEntry] = []
        var toSkip = max(0, query.offset)
        let limit = max(0, query.limit)
        guard limit > 0 else { return [] }
        try scanTextEntries(pinnedOnly: query.pinnedOnly, favoriteOnly: query.favoriteOnly,
                            tag: query.tag, contentType: single) { entry in
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
}
