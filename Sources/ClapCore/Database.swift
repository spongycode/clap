import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` is not importable from Swift; recreate it.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A bindable SQLite value.
enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

/// A prepared statement. Finalized deterministically (or on deinit as a backstop).
final class Statement {
    private(set) var handle: OpaquePointer?
    private unowned let database: Database

    init(database: Database, sql: String) throws {
        self.database = database
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database.handle, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            throw database.lastError()
        }
        self.handle = prepared
    }

    deinit { finalizeStatement() }

    func finalizeStatement() {
        if let h = handle {
            sqlite3_finalize(h)
            handle = nil
        }
    }

    func bind(_ values: [SQLValue]) throws {
        guard let h = handle else {
            throw ClapCoreError.database(code: SQLITE_MISUSE, message: "statement already finalized")
        }
        for (index, value) in values.enumerated() {
            let idx = Int32(index + 1)
            let rc: Int32
            switch value {
            case .int(let n):
                rc = sqlite3_bind_int64(h, idx, n)
            case .double(let d):
                rc = sqlite3_bind_double(h, idx, d)
            case .text(let s):
                rc = sqlite3_bind_text(h, idx, s, -1, sqliteTransient)
            case .blob(let d):
                if d.isEmpty {
                    rc = sqlite3_bind_zeroblob(h, idx, 0)
                } else {
                    rc = d.withUnsafeBytes { buf in
                        sqlite3_bind_blob(h, idx, buf.baseAddress, Int32(d.count), sqliteTransient)
                    }
                }
            case .null:
                rc = sqlite3_bind_null(h, idx)
            }
            guard rc == SQLITE_OK else { throw database.lastError() }
        }
    }

    /// Returns true when a row is available, false on completion.
    func step() throws -> Bool {
        guard let h = handle else {
            throw ClapCoreError.database(code: SQLITE_MISUSE, message: "statement already finalized")
        }
        switch sqlite3_step(h) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.lastError()
        }
    }

    // MARK: Column accessors

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
    func text(_ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: cString)
    }
}

/// Thin wrapper over a single SQLite connection.
/// Not thread-safe by itself; the owning actor serializes access.
final class Database {
    let handle: OpaquePointer

    init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let opened = h else {
            let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let h { sqlite3_close_v2(h) }
            throw ClapCoreError.database(code: rc, message: message)
        }
        self.handle = opened
        do {
            // busy_timeout first: the WAL conversion below takes locks, and
            // two processes opening a fresh DB concurrently (app + CLI) would
            // otherwise hit an unretried SQLITE_BUSY.
            try exec("PRAGMA busy_timeout=3000")
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA synchronous=NORMAL")
            try exec("PRAGMA foreign_keys=ON")
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }
    }

    deinit { sqlite3_close_v2(handle) }

    func lastError() -> ClapCoreError {
        .database(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
    var lastInsertRowid: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Executes one or more semicolon-separated statements with no binds.
    func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errMsg)
            throw ClapCoreError.database(code: rc, message: message)
        }
    }

    /// Runs a single statement with binds; discards any rows.
    func run(_ sql: String, _ binds: [SQLValue] = []) throws {
        let stmt = try Statement(database: self, sql: sql)
        defer { stmt.finalizeStatement() }
        try stmt.bind(binds)
        while try stmt.step() {}
    }

    /// Runs a query, mapping each row through `map`.
    func query<T>(_ sql: String, _ binds: [SQLValue] = [], _ map: (Statement) throws -> T) throws -> [T] {
        let stmt = try Statement(database: self, sql: sql)
        defer { stmt.finalizeStatement() }
        try stmt.bind(binds)
        var results: [T] = []
        while try stmt.step() {
            results.append(try map(stmt))
        }
        return results
    }

    func scalarInt64(_ sql: String, _ binds: [SQLValue] = []) throws -> Int64? {
        try query(sql, binds) { $0.isNull(0) ? nil : $0.int64(0) }.first ?? nil
    }

    func scalarDouble(_ sql: String, _ binds: [SQLValue] = []) throws -> Double? {
        try query(sql, binds) { $0.isNull(0) ? nil : $0.double(0) }.first ?? nil
    }

    func scalarText(_ sql: String, _ binds: [SQLValue] = []) throws -> String? {
        try query(sql, binds) { $0.text(0) }.first ?? nil
    }

    /// Runs `body` inside an IMMEDIATE transaction; rolls back on error.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: Schema

    static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS entries (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        type          TEXT NOT NULL,
        content       TEXT,
        image_path    TEXT,
        image_format  TEXT,
        content_hash  TEXT NOT NULL,
        created_at    REAL NOT NULL,
        last_used_at  REAL NOT NULL,
        size_bytes    INTEGER NOT NULL,
        is_pinned     INTEGER NOT NULL DEFAULT 0,
        use_count     INTEGER NOT NULL DEFAULT 1,
        source_app    TEXT
    );
    -- Non-unique: dedup is enforced by the lookup inside the capture
    -- transaction (BEGIN IMMEDIATE serializes writers across processes), and
    -- the lookup verifies actual content equality, so an FNV-1a collision
    -- stores both entries instead of silently discarding one forever.
    CREATE INDEX IF NOT EXISTS idx_entries_hash ON entries(type, content_hash);
    CREATE INDEX IF NOT EXISTS idx_entries_lru  ON entries(is_pinned, last_used_at);
    CREATE INDEX IF NOT EXISTS idx_entries_type ON entries(type, last_used_at DESC);
    CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
        content, content='entries', content_rowid='id', tokenize='unicode61'
    );
    CREATE TRIGGER IF NOT EXISTS entries_fts_ai AFTER INSERT ON entries BEGIN
        INSERT INTO entries_fts(rowid, content) VALUES (new.id, new.content);
    END;
    CREATE TRIGGER IF NOT EXISTS entries_fts_ad AFTER DELETE ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, content) VALUES ('delete', old.id, old.content);
    END;
    CREATE TRIGGER IF NOT EXISTS entries_fts_au AFTER UPDATE OF content ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, content) VALUES ('delete', old.id, old.content);
        INSERT INTO entries_fts(rowid, content) VALUES (new.id, new.content);
    END;
    CREATE TABLE IF NOT EXISTS config (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS stats_counters (
        key   TEXT PRIMARY KEY,
        value INTEGER NOT NULL
    );
    """

    /// Idempotent schema creation; sets user_version = 1.
    func migrate() throws {
        try transaction {
            try exec(Self.schemaSQL)
            try exec("PRAGMA user_version = 1")
        }
    }
}
