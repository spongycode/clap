import Foundation
import SQLite3
import ClapCore

/// `clap import maccy [--db <path>] [--dry-run]`
/// `clap import shell-history [--file <path>] [--dry-run]`
///
/// Imports history from Maccy (Core Data SQLite store) or shell history
/// files (zsh / bash) into clap.
enum ImportCommand {
    static let usage = """
    Usage: clap import maccy [--db <path>] [--dry-run]
           clap import shell-history [--file <path>] [--dry-run]

    Imports history from external sources into clap.
      maccy           Import clipboard history from Maccy
      shell-history   Backfill shell history from ~/.zsh_history or ~/.bash_history
      --db <path>     Path to Maccy's Storage.sqlite
      --file <path>   Path to shell history file (default: auto-detected)
      --dry-run       Show what would be imported without writing anything
    """

    // Core Data stores dates as seconds since 2001-01-01.
    private static let coreDataEpochOffset: TimeInterval = 978_307_200

    static func run(_ args: [String], context: CLIContext) async {
        let parsed = ArgParser.parse(args, boolFlags: ["--dry-run"],
                                     valueFlags: ["--db", "--file"], usage: usage)
        guard let source = parsed.positionals.first else {
            CLI.usageError("import requires a source: 'maccy' or 'shell-history'", usage: usage)
        }
        switch source {
        case "maccy":
            await runMaccy(parsed: parsed, context: context)
        case "shell-history", "shell":
            await runShellHistory(parsed: parsed, context: context)
        default:
            CLI.usageError("unknown import source '\(source)'", usage: usage)
        }
    }

    // MARK: - Shell history import

    static func runShellHistory(parsed: ArgParser, context: CLIContext) async {
        let dryRun = parsed.has("--dry-run")
        let explicitFile = parsed.value("--file")

        let fileURL: URL
        if let explicit = explicitFile {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                CLI.fail("shell history file not found: \(url.path)")
            }
            fileURL = url
        } else {
            let configured = await CLI.run { () -> String? in
                let store = try context.makeStore()
                return try await store.config("shell.histfile")
            }
            if let configured, !configured.trimmingCharacters(in: .whitespaces).isEmpty {
                let url = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    CLI.fail("configured shell history file not found: \(url.path)")
                }
                fileURL = url
            } else if let detected = ShellHistoryParser.defaultHistoryFile() {
                fileURL = detected
            } else {
                CLI.fail("could not find a shell history file (~/.zsh_history or ~/.bash_history). Specify with --file <path>.")
            }
        }

        let rawData: Data
        do {
            rawData = try Data(contentsOf: fileURL)
        } catch {
            CLI.fail("unable to read shell history file at \(fileURL.path): \(error.localizedDescription)")
        }

        let commands = ShellHistoryParser.parse(rawData)

        if dryRun {
            print("Dry run — nothing written.")
            print("""
            Shell history import
              Commands parsed: \(commands.count)
              History file:    \(fileURL.path)
            """)
            return
        }

        await CLI.run {
            let store = try context.makeStore()
            let batch = commands.map { (text: $0.text, executedAt: $0.executedAt) }
            let result = try await store.ingestShellBatch(batch, source: fileURL.lastPathComponent)
            try await store.setConfig("shell.initial_imported", value: "1")
            Notify.storeChanged()
            print("""
            Shell history import
              Commands parsed:   \(commands.count)
              New commands:      \(result.imported)
              Merged (existing): \(result.merged)
              Skipped:           \(commands.count - result.imported - result.merged)
              History file:      \(fileURL.path)
            """)
        }
    }

    // MARK: - Maccy import

    static func runMaccy(parsed: ArgParser, context: CLIContext) async {
        let dryRun = parsed.has("--dry-run")

        guard let sourceDB = resolveMaccyDB(explicit: parsed.value("--db")) else {
            CLI.fail("""
            could not find Maccy's database. Looked in:
              ~/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/
              ~/Library/Application Support/Maccy/
            Pass it explicitly with --db <path to Storage.sqlite>.
            """)
        }

        let snapshot: URL
        do {
            snapshot = try snapshotDatabase(at: sourceDB)
        } catch {
            CLI.fail("unable to snapshot Maccy database: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }

        let items: [MaccyItem]
        do {
            items = try readMaccyItems(dbPath: snapshot.path)
        } catch {
            CLI.fail("unable to read Maccy database: \(error.localizedDescription)")
        }

        var textCount = 0, imageCount = 0, merged = 0, skipped = 0
        var imageBytes: Int64 = 0

        if dryRun {
            for item in items {
                switch item.payload {
                case .text: textCount += 1
                case .image(let data, _): imageCount += 1; imageBytes += Int64(data.count)
                case .none: skipped += 1
                }
            }
            print("Dry run — nothing written.")
            printSummary(textCount: textCount, imageCount: imageCount, merged: 0,
                         skipped: skipped, imageBytes: imageBytes)
            return
        }

        await CLI.run {
            let store = try context.makeStore()
            for item in items {
                switch item.payload {
                case .text(let text):
                    if let result = try await store.importText(
                        text, createdAt: item.createdAt, lastUsedAt: item.lastUsedAt,
                        useCount: item.useCount, pinned: item.pinned, sourceApp: item.sourceApp) {
                        textCount += 1
                        if result.merged { merged += 1 }
                    } else {
                        skipped += 1
                    }
                case .image(let data, let format):
                    if let result = try await store.importImage(
                        data: data, format: format, createdAt: item.createdAt,
                        lastUsedAt: item.lastUsedAt, useCount: item.useCount,
                        pinned: item.pinned, sourceApp: item.sourceApp) {
                        imageCount += 1
                        imageBytes += Int64(data.count)
                        if result.merged { merged += 1 }
                    } else {
                        skipped += 1
                    }
                case .none:
                    skipped += 1
                }
            }

            Notify.storeChanged()
            printSummary(textCount: textCount, imageCount: imageCount, merged: merged,
                         skipped: skipped, imageBytes: imageBytes)

            // Warn when the imported images blow the eviction budget — the
            // next maintenance pass would silently evict the oldest ones.
            let stats = try await store.stats()
            if let maxRaw = try await store.config("image.max_size"),
               let maxSize = Int64(maxRaw), stats.imageBytes > maxSize {
                print("""

                Note: image storage (\(ByteSize.format(stats.imageBytes))) now exceeds the \
                \(ByteSize.format(maxSize)) limit; the oldest unpinned images will be \
                evicted on the next maintenance pass. To keep everything, raise the limit:
                  clap config set image.max_size \(ByteSize.format(((stats.imageBytes / (256 * 1024 * 1024)) + 1) * 256 * 1024 * 1024).replacingOccurrences(of: " ", with: ""))
                """)
            }
        }
    }

    private static func printSummary(textCount: Int, imageCount: Int, merged: Int,
                                     skipped: Int, imageBytes: Int64) {
        print("""
        Maccy import
          Text entries:   \(textCount)
          Image entries:  \(imageCount) (\(ByteSize.format(imageBytes)))
          Merged (already in clap): \(merged)
          Skipped (empty/oversize/unsupported): \(skipped)
        """)
    }

    // MARK: - Locate + snapshot

    private static func resolveMaccyDB(explicit: String?) -> URL? {
        let fm = FileManager.default
        if let explicit {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(
                "Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite"),
            home.appendingPathComponent("Library/Application Support/Maccy/Storage.sqlite"),
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// Copies DB + WAL + SHM into a fresh 0700 temp dir and returns the DB copy.
    private static func snapshotDatabase(at db: URL) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("clap-maccy-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let copy = dir.appendingPathComponent(db.lastPathComponent)
        try fm.copyItem(at: db, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: db.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        return copy
    }

    // MARK: - Maccy Core Data reader

    struct MaccyItem {
        enum Payload {
            case text(String)
            case image(Data, format: String)
            case none
        }
        let payload: Payload
        let createdAt: Date
        let lastUsedAt: Date
        let useCount: Int
        let pinned: Bool
        let sourceApp: String?
    }

    // Preference order per item.
    private static let textTypes = [
        "public.utf8-plain-text", "public.text",
        "public.utf16-external-plain-text", "public.utf16-plain-text",
    ]
    private static let imageTypes: [(uti: String, format: String)] = [
        ("public.png", "png"), ("public.jpeg", "jpeg"), ("public.tiff", "tiff"),
    ]

    static func readMaccyItems(dbPath: String) throws -> [MaccyItem] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw ClapCoreError.io("cannot open \(dbPath)")
        }
        defer { sqlite3_close_v2(db) }

        // One pass, contents joined to their parent item. ZITEM IS NOT NULL
        // filters orphaned content rows Maccy leaves behind.
        let sql = """
            SELECT h.Z_PK, h.ZFIRSTCOPIEDAT, h.ZLASTCOPIEDAT, h.ZNUMBEROFCOPIES,
                   h.ZPIN, h.ZAPPLICATION, c.ZTYPE, c.ZVALUE
            FROM ZHISTORYITEM h
            JOIN ZHISTORYITEMCONTENT c ON c.ZITEM = h.Z_PK
            ORDER BY h.Z_PK
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            throw ClapCoreError.io("unexpected Maccy schema: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }

        struct RawItem {
            var createdAt = Date()
            var lastUsedAt = Date()
            var useCount = 1
            var pinned = false
            var sourceApp: String?
            var contents: [String: Data] = [:]
        }
        var itemsByPK: [Int64: RawItem] = [:]
        var order: [Int64] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let pk = sqlite3_column_int64(statement, 0)
            if itemsByPK[pk] == nil {
                var item = RawItem()
                item.createdAt = Date(timeIntervalSince1970:
                    sqlite3_column_double(statement, 1) + coreDataEpochOffset)
                item.lastUsedAt = Date(timeIntervalSince1970:
                    sqlite3_column_double(statement, 2) + coreDataEpochOffset)
                item.useCount = max(1, Int(sqlite3_column_int64(statement, 3)))
                item.pinned = sqlite3_column_type(statement, 4) != SQLITE_NULL
                if sqlite3_column_type(statement, 5) != SQLITE_NULL,
                   let cString = sqlite3_column_text(statement, 5) {
                    item.sourceApp = String(cString: cString)
                }
                itemsByPK[pk] = item
                order.append(pk)
            }
            guard let typeCString = sqlite3_column_text(statement, 6) else { continue }
            let type = String(cString: typeCString)
            // Only keep representations we can import; skip HTML/RTF/etc.
            let wanted = textTypes.contains(type) || imageTypes.contains { $0.uti == type }
            guard wanted, let blob = sqlite3_column_blob(statement, 7) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 7))
            itemsByPK[pk]?.contents[type] = Data(bytes: blob, count: length)
        }

        return order.compactMap { pk -> MaccyItem? in
            guard let raw = itemsByPK[pk] else { return nil }
            return MaccyItem(payload: pickPayload(raw.contents),
                             createdAt: raw.createdAt, lastUsedAt: raw.lastUsedAt,
                             useCount: raw.useCount, pinned: raw.pinned,
                             sourceApp: raw.sourceApp)
        }
    }

    private static func pickPayload(_ contents: [String: Data]) -> MaccyItem.Payload {
        for type in textTypes {
            guard let data = contents[type] else { continue }
            let encoding: String.Encoding = type.contains("utf16") ? .utf16 : .utf8
            if let text = String(data: data, encoding: encoding) {
                return .text(text)
            }
        }
        for (uti, format) in imageTypes {
            if let data = contents[uti] {
                return .image(data, format: format)
            }
        }
        return .none
    }
}
