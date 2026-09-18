import Foundation

// MARK: - Full-history backup & restore
//
// Backup format: a single JSON file plus an `images/` sibling folder.
// {
//   "format": "clap-backup",
//   "version": 1,
//   "exportedAt": <ISO8601>,
//   "entries": [ { type, content?, imagePath?, imageFormat?, createdAt,
//                  lastUsedAt, sizeBytes, isPinned, isFavorite, useCount,
//                  sourceApp?, shortcut?, tags: [] } ]
// }
// Image rows reference `images/<file>` next to the JSON. Restore replays
// every row through importText/importImage so dedup, FTS indexing, and
// metadata merge all behave exactly like the Maccy importer.

extension ClipboardStore {

    struct BackupDocument: Codable {
        let format: String
        let version: Int
        let exportedAt: Date
        let entries: [BackupEntry]
    }

    struct BackupEntry: Codable {
        let type: String
        let content: String?
        let imagePath: String?
        let imageFormat: String?
        let createdAt: Date
        let lastUsedAt: Date
        let sizeBytes: Int64
        let isPinned: Bool
        let isFavorite: Bool
        let useCount: Int
        let sourceApp: String?
        let shortcut: String?
        let tags: [String]
    }

    static let backupFormatIdentifier = "clap-backup"
    static let backupFormatVersion = 1
    static let backupImagesFolderName = "images"

    /// Writes `backup.json` + `images/` into `directory` (created if needed).
    /// Returns the number of entries exported. Image bytes are copied from
    /// the store's image folder; missing files fail the export loudly rather
    /// than producing a partial backup.
    @discardableResult
    public func exportBackup(to directory: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let imagesDir = directory.appendingPathComponent(Self.backupImagesFolderName, isDirectory: true)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        var backupEntries: [BackupEntry] = []
        var copiedImageFiles = Set<String>()

        var offset = 0
        while true {
            let batch = try list(type: nil, limit: 500, offset: offset)
            if batch.isEmpty { break }
            for entry in batch {
                if let imagePath = entry.imagePath {
                    let source = dataDir.appendingPathComponent("images", isDirectory: true)
                        .appendingPathComponent(imagePath)
                    let destination = imagesDir.appendingPathComponent(imagePath)
                    if !copiedImageFiles.contains(imagePath) {
                        if fm.fileExists(atPath: destination.path) {
                            try? fm.removeItem(at: destination)
                        }
                        try fm.copyItem(at: source, to: destination)
                        copiedImageFiles.insert(imagePath)
                    }
                }
                backupEntries.append(BackupEntry(
                    type: entry.type.rawValue,
                    content: entry.content,
                    imagePath: entry.imagePath,
                    imageFormat: entry.imageFormat,
                    createdAt: entry.createdAt,
                    lastUsedAt: entry.lastUsedAt,
                    sizeBytes: entry.sizeBytes,
                    isPinned: entry.isPinned,
                    isFavorite: entry.isFavorite,
                    useCount: entry.useCount,
                    sourceApp: entry.sourceApp,
                    shortcut: entry.shortcut,
                    tags: entry.tags))
            }
            offset += batch.count
        }

        let document = BackupDocument(
            format: Self.backupFormatIdentifier,
            version: Self.backupFormatVersion,
            exportedAt: clock(),
            entries: backupEntries)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)

        let jsonURL = directory.appendingPathComponent("backup.json")
        try data.write(to: jsonURL, options: .atomic)
        try fm.setAttributes(CoreConstants.ownerOnlyFileAttributes, ofItemAtPath: jsonURL.path)

        return backupEntries.count
    }

    /// Restores a backup produced by `exportBackup`. Returns
    /// (imported, merged) counts. Rows missing their referenced image file
    /// are skipped (reported in `skipped`).
    @discardableResult
    public func importBackup(from directory: URL) async throws -> (imported: Int, merged: Int, skipped: Int) {
        let jsonURL = directory.appendingPathComponent("backup.json")
        let data = try Data(contentsOf: jsonURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: BackupDocument
        do {
            document = try decoder.decode(BackupDocument.self, from: data)
        } catch {
            throw ClapCoreError.io("invalid clap backup file")
        }
        guard document.format == Self.backupFormatIdentifier else {
            throw ClapCoreError.io("not a clap backup file")
        }

        let imagesDir = directory.appendingPathComponent(Self.backupImagesFolderName, isDirectory: true)
        var imported = 0
        var merged = 0
        var skipped = 0

        for entry in document.entries {
            guard let type = EntryType(rawValue: entry.type) else {
                skipped += 1
                continue
            }

            switch type {
            case .text, .shell:
                guard let content = entry.content else {
                    skipped += 1
                    continue
                }
                if let result = try await importText(
                    content,
                    createdAt: entry.createdAt,
                    lastUsedAt: entry.lastUsedAt,
                    useCount: entry.useCount,
                    pinned: entry.isPinned,
                    sourceApp: entry.sourceApp,
                    as: type) {
                    if result.merged { merged += 1 } else { imported += 1 }
                    _ = try? setFavorite(entry.isFavorite, id: result.id)
                    if let shortcut = entry.shortcut {
                        _ = try? setShortcut(shortcut, id: result.id)
                    }
                    for tag in entry.tags {
                        _ = try? addTag(tag, entryID: result.id)
                    }
                } else {
                    skipped += 1
                }

            case .image:
                guard let imagePath = entry.imagePath, let format = entry.imageFormat else {
                    skipped += 1
                    continue
                }
                let fileURL = imagesDir.appendingPathComponent(imagePath)
                guard let imageBytes = try? Data(contentsOf: fileURL), !imageBytes.isEmpty else {
                    skipped += 1
                    continue
                }
                if let result = try await importImage(
                    data: imageBytes,
                    format: format,
                    createdAt: entry.createdAt,
                    lastUsedAt: entry.lastUsedAt,
                    useCount: entry.useCount,
                    pinned: entry.isPinned,
                    sourceApp: entry.sourceApp) {
                    if result.merged { merged += 1 } else { imported += 1 }
                    _ = try? setFavorite(entry.isFavorite, id: result.id)
                    for tag in entry.tags {
                        _ = try? addTag(tag, entryID: result.id)
                    }
                } else {
                    skipped += 1
                }
            }
        }

        return (imported, merged, skipped)
    }
}
