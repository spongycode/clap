import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

/// The single entry point. An actor so all DB access is serialized per process.
/// Multi-process safety comes from SQLite WAL + busy_timeout.
///
/// Security note: clipboard content is never logged anywhere in this module.
public actor ClipboardStore {

    public nonisolated let dataDir: URL
    let db: Database
    let clock: @Sendable () -> Date
    let ocr: any OCREngine

    static let logger = Logger(subsystem: ClapIdentity.bundleID, category: "store")

    private nonisolated var imagesDir: URL {
        dataDir.appendingPathComponent("images", isDirectory: true)
    }
    private nonisolated var thumbnailsDir: URL {
        dataDir.appendingPathComponent("thumbnails", isDirectory: true)
    }
    nonisolated var imagesDirectory: URL { imagesDir }
    nonisolated var thumbnailsDirectory: URL { thumbnailsDir }

    public init(dataDir: URL? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                ocr: any OCREngine = VisionOCREngine()) throws {
        let resolved = Self.resolveDataDir(dataDir)
        self.dataDir = resolved
        self.clock = now
        self.ocr = ocr
        let fm = FileManager.default
        try fm.createDirectory(at: resolved, withIntermediateDirectories: true,
                               attributes: CoreConstants.ownerOnlyDirectoryAttributes)
        try fm.createDirectory(at: resolved.appendingPathComponent("images", isDirectory: true),
                               withIntermediateDirectories: true,
                               attributes: CoreConstants.ownerOnlyDirectoryAttributes)
        try fm.createDirectory(at: resolved.appendingPathComponent("thumbnails", isDirectory: true),
                               withIntermediateDirectories: true,
                               attributes: CoreConstants.ownerOnlyDirectoryAttributes)
        // Pre-existing dirs keep their old mode; tighten them too.
        for dir in [resolved, resolved.appendingPathComponent("images"),
                    resolved.appendingPathComponent("thumbnails")] {
            try? fm.setAttributes(CoreConstants.ownerOnlyDirectoryAttributes, ofItemAtPath: dir.path)
        }
        self.db = try Database(path: resolved.appendingPathComponent("clap.sqlite").path)
        try db.migrate()
        // The DB (and its WAL/SHM siblings) hold clipboard text.
        for suffix in ["", "-wal", "-shm"] {
            let path = resolved.appendingPathComponent("clap.sqlite\(suffix)").path
            if fm.fileExists(atPath: path) {
                try? fm.setAttributes(CoreConstants.ownerOnlyFileAttributes, ofItemAtPath: path)
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

    // MARK: - Shared row plumbing

    private static let entryColumnNames = [
        "id", "type", "content", "image_path", "image_format", "content_hash",
        "created_at", "last_used_at", "size_bytes", "is_pinned", "is_favorite",
        "use_count", "source_app", "shortcut"
    ]

    private static let tagsSubquery =
        "(SELECT GROUP_CONCAT(tag, '\(CoreConstants.tagConcatSeparator)') FROM entry_tags WHERE entry_id = entries.id) AS tags"

    static let entryColumns: String =
        (entryColumnNames + [tagsSubquery]).joined(separator: ", ")

    /// entryColumns with every column prefixed for joined queries (FTS search).
    static var prefixedEntryColumns: String {
        let prefixed = entryColumnNames.map { "e.\($0)" }
        let tagsPrefixed = tagsSubquery.replacingOccurrences(of: "entries.id", with: "e.id")
        return (prefixed + [tagsPrefixed]).joined(separator: ", ")
    }

    static func rowToEntry(_ stmt: Statement) -> ClipboardEntry {
        let tagStr = stmt.text(14)
        let tags = tagStr?.components(separatedBy: CoreConstants.tagConcatSeparator)
            .filter { !$0.isEmpty } ?? []
        return ClipboardEntry(
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
            isFavorite: stmt.int64(10) != 0,
            useCount: Int(stmt.int64(11)),
            sourceApp: stmt.text(12),
            shortcut: stmt.text(13),
            tags: tags
        )
    }

    func firstEntry(_ whereClause: String, _ binds: [SQLValue]) throws -> ClipboardEntry? {
        try db.query("SELECT \(Self.entryColumns) FROM entries WHERE \(whereClause) LIMIT 1",
                     binds, Self.rowToEntry).first
    }

    func incrementCounter(_ key: String) throws {
        try db.run("""
            INSERT INTO stats_counters (key, value) VALUES (?, 1)
            ON CONFLICT(key) DO UPDATE SET value = value + 1
            """, [.text(key)])
    }

    static let touchSQL = "UPDATE entries SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?"

    func touchRow(id: Int64, at timestamp: Double) throws {
        try db.run(Self.touchSQL, [.double(timestamp), .int(id)])
    }

    static let insertEntrySQL = """
        INSERT INTO entries (type, content, image_path, image_format, content_hash,
                             created_at, last_used_at, size_bytes, is_pinned, use_count, source_app)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    func insertEntry(type: EntryType, content: String?, imagePath: String?, imageFormat: String?,
                     hash: String, createdAt: Double, lastUsedAt: Double, sizeBytes: Int64,
                     pinned: Bool, useCount: Int, sourceApp: String?) throws -> Int64 {
        try db.run(Self.insertEntrySQL, [
            .text(type.rawValue),
            content.map(SQLValue.text) ?? .null,
            imagePath.map(SQLValue.text) ?? .null,
            imageFormat.map(SQLValue.text) ?? .null,
            .text(hash),
            .double(createdAt), .double(lastUsedAt),
            .int(sizeBytes), .int(pinned ? 1 : 0), .int(Int64(max(1, useCount))),
            sourceApp.map(SQLValue.text) ?? .null
        ])
        return db.lastInsertRowid
    }

    /// yyyy-MM-dd for the given day (local calendar).
    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Strips whitespace and leading '#', lowercases. Returns nil when empty
    /// or when the tag contains the GROUP_CONCAT separator (would corrupt
    /// row mapping).
    static func normalizeTag(_ rawTag: String) -> String? {
        let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
        guard !tag.isEmpty, !tag.contains(CoreConstants.tagConcatSeparator) else { return nil }
        return tag
    }

    func configInt(_ key: String) throws -> Int {
        if let raw = try config(key), let value = Int(raw) { return value }
        return Int(Self.configDefaults[key] ?? "0") ?? 0
    }

    func configInt64(_ key: String) throws -> Int64 {
        if let raw = try config(key), let value = Int64(raw) { return value }
        return Int64(Self.configDefaults[key] ?? "0") ?? 0
    }

    /// Deletes rows by id. Must already be inside a transaction.
    func deleteRowsInCurrentTransaction(_ entries: [ClipboardEntry]) throws {
        guard !entries.isEmpty else { return }
        for chunk in entries.map(\.id).chunked(CoreConstants.sqlBatchSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.run("DELETE FROM entries WHERE id IN (\(placeholders))", chunk.map(SQLValue.int))
        }
    }

    /// Removes image + thumbnail files for evicted/deleted image entries.
    /// Failures are logged (metadata only): silent data retention here would
    /// defeat byte-budget eviction.
    func removeFiles(for entries: [ClipboardEntry]) {
        let fm = FileManager.default
        func remove(_ url: URL, label: String) {
            do {
                try fm.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                return
            } catch {
                Self.logger.error("\(label, privacy: .public) delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        for entry in entries where entry.type == .image {
            if let path = entry.imagePath {
                remove(imagesDir.appendingPathComponent(path), label: "image")
            }
            remove(thumbnailsDir.appendingPathComponent("\(entry.contentHash).png"), label: "thumbnail")
        }
    }
}
