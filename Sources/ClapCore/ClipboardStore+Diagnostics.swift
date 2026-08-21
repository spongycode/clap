import Foundation

// MARK: - Settings, stats, doctor diagnostics

extension ClipboardStore {

    static let configDefaults: [String: String] = [
        ConfigKey.textMaxEntries: "100000",
        ConfigKey.textMaxSize: "52428800",
        ConfigKey.imageMaxEntries: "500",
        ConfigKey.imageMaxSize: "104857600",
        ConfigKey.monitoringPaused: "0",
        ConfigKey.exclusions: "[]",
        ConfigKey.retentionDays: "0",
        ConfigKey.launchAtLogin: "0",
        // Synthesize Cmd+V into the frontmost app after copying from the UI
        // (Maccy-style). Requires Accessibility permission; falls back to
        // copy-only when not granted.
        ConfigKey.pasteOnCopy: "1",
        // Shell history (zsh/bash) ingestion.
        ConfigKey.shellEnabled: "1",
        ConfigKey.shellMaxEntries: "50000",
        ConfigKey.shellMaxSize: "10485760",   // 10 MB
        ConfigKey.shellHistfile: ""          // empty = auto-detect
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
        _ = try db.query("SELECT type, COUNT(*), COALESCE(SUM(size_bytes), 0) FROM entries GROUP BY type") { stmt in
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
        let day = Self.dayKey(clock())
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

        checks.append(dataDirectoryCheck(dir))
        let database = databaseOpenCheck(dir.appendingPathComponent("clap.sqlite").path)
        checks.append(database.check)
        checks.append(requiredTablesCheck(database.handle))
        checks.append(requiredIndexesCheck(database.handle))
        checks.append(ftsAvailabilityCheck())
        checks.append(imagesDirectoryCheck(dir))
        checks.append(diskSpaceCheck(probeURL: fm.fileExists(atPath: dir.path) ? dir : fm.homeDirectoryForCurrentUser))
        checks.append(shellHistoryCheck(database.handle))

        return checks
    }

    private static func dataDirectoryCheck(_ dir: URL) -> (name: String, ok: Bool, detail: String) {
        var isDir: ObjCBool = false
        let dirExists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
        let dirWritable = dirExists && FileManager.default.isWritableFile(atPath: dir.path)
        return ("data directory", dirWritable,
                dirExists ? (dirWritable ? dir.path : "not writable: \(dir.path)")
                          : "missing: \(dir.path)")
    }

    private static func databaseOpenCheck(_ dbPath: String) -> (check: (name: String, ok: Bool, detail: String), handle: Database?) {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return (("database opens", false, "missing: \(dbPath)"), nil)
        }
        do {
            let database = try Database(path: dbPath)
            return (("database opens", true, dbPath), database)
        } catch {
            return (("database opens", false, "\(error)"), nil)
        }
    }

    private static func requiredTablesCheck(_ database: Database?) -> (name: String, ok: Bool, detail: String) {
        let requiredTables = ["entries", "entries_fts", "config", "stats_counters"]
        guard let database else { return ("required tables", false, "database unavailable") }
        let found = (try? database.scalarInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('entries','entries_fts','config','stats_counters')"
        )) ?? 0
        let ok = found == Int64(requiredTables.count)
        return ("required tables", ok,
                ok ? requiredTables.joined(separator: ", ") : "found \(found) of \(requiredTables.count)")
    }

    private static func requiredIndexesCheck(_ database: Database?) -> (name: String, ok: Bool, detail: String) {
        let requiredIndexes = ["idx_entries_hash", "idx_entries_lru", "idx_entries_type"]
        guard let database else { return ("indexes", false, "database unavailable") }
        let found = (try? database.scalarInt64(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'"
            + " AND name IN ('idx_entries_hash','idx_entries_lru','idx_entries_type')"
        )) ?? 0
        let ok = found == Int64(requiredIndexes.count)
        return ("indexes", ok, ok ? requiredIndexes.joined(separator: ", ")
                                  : "found \(found) of \(requiredIndexes.count)")
    }

    private static func ftsAvailabilityCheck() -> (name: String, ok: Bool, detail: String) {
        let ftsAvailable: Bool = {
            guard let probe = try? Database(path: ":memory:") else { return false }
            return (try? probe.exec("CREATE VIRTUAL TABLE fts_probe USING fts5(x)")) != nil
        }()
        return ("FTS5 available", ftsAvailable,
                ftsAvailable ? "fts5 module present" : "fts5 module missing")
    }

    private static func imagesDirectoryCheck(_ dir: URL) -> (name: String, ok: Bool, detail: String) {
        let imagesPath = dir.appendingPathComponent("images", isDirectory: true).path
        var imagesIsDir: ObjCBool = false
        let imagesOK = FileManager.default.fileExists(atPath: imagesPath, isDirectory: &imagesIsDir)
            && imagesIsDir.boolValue && FileManager.default.isWritableFile(atPath: imagesPath)
        return ("images directory", imagesOK, imagesOK ? imagesPath : "missing or not writable: \(imagesPath)")
    }

    private static func diskSpaceCheck(probeURL: URL) -> (name: String, ok: Bool, detail: String) {
        if let values = try? probeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            let ok = free > CoreConstants.minDiskFreeBytes
            return ("disk space", ok, "\(ByteSize.format(free)) free")
        }
        return ("disk space", false, "unable to determine free space")
    }

    private static func shellHistoryCheck(_ database: Database?) -> (name: String, ok: Bool, detail: String) {
        let shellHistfile: URL? = {
            if let custom = try? database?.scalarText("SELECT value FROM config WHERE key = ?",
                                                      [.text(ConfigKey.shellHistfile)]),
               !custom.trimmingCharacters(in: .whitespaces).isEmpty {
                return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            }
            return ShellHistoryParser.defaultHistoryFile()
        }()
        if let shellHistfile {
            let readable = FileManager.default.isReadableFile(atPath: shellHistfile.path)
            return ("shell history", readable, readable ? shellHistfile.path : "not readable: \(shellHistfile.path)")
        }
        return ("shell history", true, "no ~/.zsh_history or ~/.bash_history found (auto-detect)")
    }
}
