# clap — Architecture Contract

Native macOS clipboard manager. Local-first, no network, no telemetry.
This document is the binding contract between the targets. Do not
deviate from public API signatures, schema, or IPC names without updating
this file.

## Targets

- `ClapCore` (library): SQLite storage, FTS5 search, normalization, hashing,
  dedup, LRU eviction, settings, image file store, stats, doctor checks, OCR
  text extraction, and shared text analysis (color/case/Base64/URL/JWT/epoch).
  **No AppKit/SwiftUI imports** (Foundation + CoreGraphics/ImageIO +
  UniformTypeIdentifiers + CryptoKit + CoreImage + Vision allowed — Vision
  powers the injectable `OCREngine`, CoreImage the QR generator).
- `ClapApp` (executable): NSApplication accessory app. Pasteboard monitor,
  Carbon global hotkey (configurable), SwiftUI floating panel (Classic/Media/
  Shell/Favs tabs), menu bar item, settings window.
- `ClapCLIKit` (library): all `clap` command logic and output formatting as a
  unit-testable library. May import AppKit only for NSPasteboard writes
  (`clap copy`) and NSWorkspace process probing.
- `clap` (executable, Sources/ClapCLI): thin entry point delegating to
  ClapCLIKit.

## Data locations

- Base dir: `~/Library/Application Support/clap/`
  (override with env var `CLAP_DATA_DIR` — used by tests and CLI `--data-dir`).
- Database: `<base>/clap.sqlite` (WAL mode).
- Images: `<base>/images/<content_hash>.<ext>` (original data, written atomically).
- Thumbnails: `<base>/thumbnails/<content_hash>.png` (max 400px long edge).

## Database schema (SQLite, user_version = 2)

```sql
CREATE TABLE IF NOT EXISTS entries (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    type          TEXT NOT NULL,              -- 'text' | 'image' | 'shell'
    content       TEXT,                       -- normalized text / OCR text; NULL for images
    image_path    TEXT,                       -- relative path under images/; NULL for text
    image_format  TEXT,                       -- 'png','jpeg','tiff',...
    content_hash  TEXT NOT NULL,              -- 64-bit FNV-1a hex for text, SHA256 hex for images
    created_at    REAL NOT NULL,              -- unix epoch seconds
    last_used_at  REAL NOT NULL,
    size_bytes    INTEGER NOT NULL,
    is_pinned     INTEGER NOT NULL DEFAULT 0,
    is_favorite   INTEGER NOT NULL DEFAULT 0,
    use_count     INTEGER NOT NULL DEFAULT 1,
    source_app    TEXT,                       -- bundle id of frontmost app at capture, optional
    shortcut      TEXT                        -- snippet abbreviation trigger, e.g. ';email'
);
-- Non-unique: dedup is enforced by lookup-inside-transaction (BEGIN IMMEDIATE
-- serializes writers across processes) with content equality verified, so a
-- 64-bit hash collision stores both entries rather than discarding one.
CREATE INDEX IF NOT EXISTS idx_entries_hash ON entries(type, content_hash);
CREATE INDEX IF NOT EXISTS idx_entries_lru  ON entries(is_pinned, last_used_at);
CREATE INDEX IF NOT EXISTS idx_entries_type ON entries(type, last_used_at DESC);
CREATE INDEX IF NOT EXISTS idx_entries_shortcut ON entries(shortcut);
CREATE INDEX IF NOT EXISTS idx_entries_fav ON entries(is_favorite, last_used_at DESC);

CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
    content, content='entries', content_rowid='id', tokenize='unicode61'
);
-- FTS kept in sync with triggers on entries (insert/delete/update of content).

CREATE TABLE IF NOT EXISTS config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS stats_counters (
    key   TEXT PRIMARY KEY,                   -- e.g. 'events:2026-08-15', 'dups:2026-08-15'
    value INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS entry_tags (
    entry_id   INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    tag        TEXT NOT NULL COLLATE NOCASE,
    created_at REAL NOT NULL,
    PRIMARY KEY (entry_id, tag)
);
CREATE INDEX IF NOT EXISTS idx_entry_tags_tag ON entry_tags(tag, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_entry_tags_entry ON entry_tags(entry_id);
```

## Config keys (strings in `config` table, typed accessors in Settings)

All keys are constants on `ConfigKey` (CoreConstants.swift); defaults live in
`ClipboardStore.configDefaults`, so `clap config get` lists every key.

- `text.max_entries` (Int, default 100_000) / `text.max_size` (bytes, default 50MB)
- `image.max_entries` (Int, default 500) / `image.max_size` (bytes, default 100MB)
- `shell.max_entries` (Int, default 50_000) / `shell.max_size` (bytes, default 10MB)
- `shell.enabled` ("0"/"1", default "1") — watch and ingest shell history
- `shell.histfile` (path, default "" = auto-detect `$HISTFILE`, ~/.zsh_history, ~/.bash_history)
- `shell.initial_imported` ("0"/"1", default "0") — app sets "1" after the
  one-time history backfill succeeds
- `monitoring.paused` ("0"/"1", default "0")
- `exclusions` (JSON array of bundle ids, default `[]`)
- `retention.days` (Int, 0 = never, default 0)
- `launch_at_login` ("0"/"1", default "0")
- `paste.on_copy` ("0"/"1", default "1") — after a UI copy, synthesize Cmd+V
  into the frontmost app (needs Accessibility; AppleScript fallback)
- `snippets.enabled` ("0"/"1", default "1") — snippet expansion keystroke tap
- `ui.hotkey` (preset id, default "cmd+shift+v"; must match
  `HotKeyDefinition.defaultID`)
- `ui.panel_frame` (NSStringFromRect; no default — unset means "center")

Size values accept human forms in CLI (`50MB`, `1GB`) — parse in ClapCore
(`ByteSize.parse/format`).

## ClapCore public API (implement exactly)

```swift
public enum EntryType: String, Codable, Sendable, CaseIterable { case text, image, shell }

public struct ClipboardEntry: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let type: EntryType
    public let content: String?        // normalized text; OCR text for images
    public let imagePath: String?      // relative path under images/
    public let imageFormat: String?
    public let contentHash: String
    public let createdAt: Date
    public let lastUsedAt: Date
    public let sizeBytes: Int64
    public let isPinned: Bool
    public let isFavorite: Bool
    public let useCount: Int
    public let sourceApp: String?
    public let shortcut: String?       // snippet trigger, e.g. ";email"
    public let tags: [String]
}

public struct SearchQuery: Sendable {
    public var text: String?           // FTS terms / phrase (quoted)
    public var regex: String?          // regex pattern (mutually exclusive with text)
    public var type: EntryType?        // single-type filter; wins over `types`
    public var types: Set<EntryType>?  // multi-type filter (Classic = text+image)
    public var pinnedOnly: Bool
    public var favoriteOnly: Bool
    public var tag: String?
    public var limit: Int
    public var offset: Int
    public var effectiveTypes: Set<EntryType>? { get }
    /// Parses UI/CLI query syntax: bare terms, "quoted phrase",
    /// `regex:<pat>`, `type:text|image|shell`, `tag:<name>`. Unknown filters ignored.
    public static func parse(_ raw: String, limit: Int, offset: Int) -> SearchQuery
}

public struct StoreStats: Sendable {
    public let textCount: Int, imageCount: Int, shellCount: Int
    public let textBytes: Int64, imageBytes: Int64, shellBytes: Int64
    public let pinnedCount: Int
    public let eventsToday: Int, duplicatesAvoidedToday: Int
    public let oldestEntry: Date?
}

/// The single entry point. An actor so all DB access is serialized per process.
/// Multi-process safety comes from SQLite WAL + busy_timeout. Implementation is
/// split across ClipboardStore+Capture/+Query/+Mutations/+Maintenance/
/// +Diagnostics/+Backup.
public actor ClipboardStore {
    public init(dataDir: URL? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                ocr: any OCREngine = VisionOCREngine()) throws
    public nonisolated let dataDir: URL

    // Capture (fast path): normalize → hash → indexed lookup → insert or touch.
    // OCR runs OUTSIDE the write transaction and off the actor executor.
    public func captureText(_ raw: String, sourceApp: String?) throws -> (entry: ClipboardEntry, wasDuplicate: Bool)?
    public func captureImage(data: Data, format: String, sourceApp: String?) async throws -> (entry: ClipboardEntry, wasDuplicate: Bool)?
    public func updateOCRText(for entryID: Int64, ocrText: String) throws

    // Shell history (no daily clipboard counters; re-runs merge into use_count)
    public func ingestShell(_ command: String, executedAt: Date?, source: String? = nil) throws -> (id: Int64, merged: Bool)?
    public func ingestShellBatch(_ commands: [(text: String, executedAt: Date?)], source: String? = nil) throws -> (imported: Int, merged: Int)

    // Import (preserve metadata; duplicates merge)
    public func importText(_ raw: String, createdAt: Date, lastUsedAt: Date, useCount: Int, pinned: Bool, sourceApp: String?, as type: EntryType = .text) async throws -> (id: Int64, merged: Bool)?
    public func importImage(data: Data, format: String, createdAt: Date, lastUsedAt: Date, useCount: Int, pinned: Bool, sourceApp: String?) async throws -> (id: Int64, merged: Bool)?

    // Queries
    public func list(type: EntryType?, limit: Int, offset: Int) throws -> [ClipboardEntry]
    public func search(_ query: SearchQuery) throws -> [ClipboardEntry]
    public func entry(id: Int64) throws -> ClipboardEntry?
    public func count(type: EntryType?) throws -> Int

    // Mutations
    public func touch(id: Int64) throws
    public func delete(id: Int64) throws -> Bool
    public func deleteMatching(text: String) throws -> Int
    public func deleteMatching(regexPattern: String) throws -> Int
    public func setPinned(_ pinned: Bool, id: Int64) throws -> Bool
    public func setFavorite(_ favorite: Bool, id: Int64) throws -> Bool
    public func setShortcut(_ shortcut: String?, id: Int64) throws -> Bool
    public func allShortcuts() throws -> [String: String]
    public func addTag(_ rawTag: String, entryID: Int64) throws -> Bool
    public func removeTag(_ rawTag: String, entryID: Int64) throws -> Bool
    public func setTags(_ tags: [String], entryID: Int64) throws
    public func tags(for entryID: Int64) throws -> [String]
    public func allTags() throws -> [(tag: String, count: Int)]
    public func clearAll() throws -> Int   // removes EVERYTHING incl. pinned/favorites; wipes image files

    // Maintenance (background workers / CLI) — pinned AND favorites exempt
    public func enforceLimits() throws -> Int
    public func applyRetention() throws -> Int
    public func vacuumIfNeeded() throws

    // Backup: backup.json (format "clap-backup" v1) + images/ folder
    public func exportBackup(to directory: URL) throws -> Int
    public func importBackup(from directory: URL) async throws -> (imported: Int, merged: Int, skipped: Int)

    // Image helpers
    public func imageFileURL(for entry: ClipboardEntry) -> URL?
    public func thumbnailURL(for entry: ClipboardEntry) throws -> URL?  // generates lazily, atomically

    // Settings / stats / doctor
    public func config(_ key: String) throws -> String?
    public func setConfig(_ key: String, value: String) throws
    public func allConfig() throws -> [(key: String, value: String)]   // defaults merged in
    public func stats() throws -> StoreStats
    public nonisolated static func doctorChecks(dataDir: URL?) -> [(name: String, ok: Bool, detail: String)]
}

// Pure helpers, unit-testable without a store:
public enum TextNormalizer { public static func normalize(_ s: String) -> String }
public enum ContentHasher {
    public static func textHash(_ normalized: String) -> String   // FNV-1a 64 hex
    public static func imageHash(_ data: Data) -> String          // SHA256 hex (CryptoKit)
}
public enum ByteSize {
    public static func parse(_ s: String) -> Int64?               // "50MB", "1.5GB", "1024"
    public static func format(_ bytes: Int64) -> String
}
public enum SafeRegex {
    /// Case-insensitive by default ((?-i) opts out). Length-capped pattern and
    /// input slice; scans also have a wall-clock budget.
    public static func compile(_ pattern: String) throws -> NSRegularExpression
}
public enum ShellHistoryParser { /* zsh (metafied, extended, multiline) + bash */ }
public enum TextSummaries {
    public static func singleLine(_ s: String, maxChars: Int) -> String
    public static func relativeTime(_ date: Date, now: Date) -> String
}
public enum ImageFormats {
    public static func uti(forFormat format: String) -> String?
}
public enum ConfigKey { /* typed constants for every config-table key */ }
public enum ClapVersion { public static let current: String }   // single version source

/// Injectable OCR seam (Vision-backed default; tests use stubs).
public protocol OCREngine: Sendable {
    func recognizeText(from imageData: Data) async -> String?
}
public struct VisionOCREngine: OCREngine {}

// Shared clipboard content analysis (used by the app's preview smart cards):
public struct ParsedColor: Sendable, Equatable {}
public enum ColorParser { public static func parse(_ raw: String?) -> ParsedColor? }
public enum CaseConverter { /* camel/pascal/snake/kebab/constant/upper/lower/title */ }
public enum TextTransformer { /* Base64 + URL encode/decode with length guards */ }
public struct JWTData: Sendable, Equatable { public static func parse(_ text: String?) -> JWTData? }
public struct EpochData: Sendable, Equatable { public static func parse(_ text: String?) -> EpochData? }
public struct JSONData: Sendable, Equatable { public static func parse(_ text: String?) -> JSONData? }
public struct JSONRepairResult: Sendable, Equatable { public let repaired: String; public let fixes: [String] }
public enum JSONRepair { public static func repair(_ source: String) -> JSONRepairResult? }
public enum QRCodeBuilder { /* CoreImage QR, level M, <= 2000 bytes */ }

// IPC names shared by both processes:
public enum ClapIdentity { public static let bundleID = "com.spongycode.clap" }
public enum IPCNotifications {
    public static let openUI = "com.spongycode.clap.openUI"
    public static let storeChanged = "com.spongycode.clap.storeChanged"
    public static let configChanged = "com.spongycode.clap.configChanged"
}
```

Notes:
- FTS query building: escape user terms; bare terms → prefix match (`term*`)
  AND-combined; quoted phrase → FTS phrase. Regex search: SQL-side candidate
  scan in `last_used_at DESC` order with row limit batches (never load all
  rows), applying compiled regex per row, capped total scan (e.g. 20k rows)
  to avoid pathological latency.
- Default ordering everywhere: pinned first optional in UI layer; store returns
  `ORDER BY last_used_at DESC`.
- Eviction: per-category (text/image/shell) count and byte limits applied to
  rows that are neither pinned nor favorite (those live outside the budget —
  counting them would let enough of them permanently starve new captures);
  delete lowest `last_used_at` first; entries larger than the whole category budget are
  evicted first; delete image files + thumbnails for evicted images.
- Capture rejects content larger than the category's max_size outright (a
  single oversize entry must never trigger history-wiping eviction).
- All writes in transactions; `PRAGMA journal_mode=WAL; synchronous=NORMAL;
  busy_timeout=3000; foreign_keys=ON`.
- Daily counters: increment `events:<yyyy-mm-dd>` on every capture,
  `dups:<yyyy-mm-dd>` on duplicate hit.
- Never log clipboard content. Log metadata only, via os.Logger.

## IPC (app ↔ CLI), DistributedNotificationCenter names

- `com.spongycode.clap.openUI` — CLI asks app to show panel.
- `com.spongycode.clap.storeChanged` — either side mutated the DB; app reloads
  visible page, app also posts after captures so a second observer (nothing
  today) could react.
- `com.spongycode.clap.configChanged` — settings changed (pause/resume, limits).

CLI `clap` (no args) posts `openUI`; if app isn't running (check
`NSRunningApplication` by bundle id `com.spongycode.clap` fails → also try
pgrep ClapApp), print hint to start the app.

## App specifics

- Activation policy `.accessory` (no Dock icon). `LSUIElement` in packaged app.
- Hotkey: Carbon `RegisterEventHotKey`, no Accessibility needed. Default
  ⌘⇧V; 7 presets (`HotKeyDefinition.presets`: ⌘⇧V, ⌘⇧B, ⌘⇧C, ⌘⇧Space,
  ⌥Space, ⌃⌥V, ⌃⌘V) chosen in Settings, persisted in `ui.hotkey`, and
  re-registered live on `configChanged`.
- Panel: borderless `NSPanel` (floating, `.nonactivatingPanel`, `.resizable`,
  min 460×280) hosting SwiftUI, with Liquid Glass (`NSGlassEffectView`) on
  macOS 26 and `NSVisualEffectView` fallback. Movable by background drag;
  resized via `EdgeResizeOverlay` handles (9pt edges / 20pt corners). The
  user-chosen frame is debounce-persisted to `ui.panel_frame` and restored on
  open (fallback: centered on the mouse's screen). Esc closes. Opens with
  search focused.
- Tabs: Classic (text+image), Shell, Favs (favorites, or one tag pinboard via
  the tag pill bar), Media (image grid).
- Preview (slideout): the panel window itself animates wider (0.28 s) to
  reveal a preview pane, auto-opening 1 s after a selection; left/right side
  chosen by screen room; draggable divider (content min 460, pane min 320).
  Shows scrollable text (TextKit 2 for ≥1000 chars, with search-match
  highlighting) or the image, smart cards (color, Base64/URL, JWT, epoch,
  JSON pretty/minify/repair, OCR, QR), an Actions row (case/encoding
  transforms, QR, snippet shortcut, tags), and metadata (id + transient-marked
  Copy ID button, type, dimensions, size, first/last used, use count, source
  app, tags, pin/favorite).
- Pasteboard monitor: poll `NSPasteboard.general.changeCount` every 150 ms on a
  background task; on change, read text/image off the main thread, skip when
  paused, skip when frontmost app is in exclusions, skip transient/concealed/
  auto-generated pasteboard types, then call `store.captureText/Image`. When
  clap itself writes (copy action) it calls expect/confirm with the resulting
  changeCount so its own write only touches recency, while a foreign copy in
  the same poll window is still captured.
- Shell history monitor: one-time backfill on first launch (sets
  `shell.initial_imported`), then polls the history file every 2 s reading only
  appended bytes (inode change or shrink → re-anchor at EOF; partial trailing
  line carried over).
- Snippet expander: CGEvent keystroke tap (needs Accessibility; retries every
  2 s until granted), 40-char buffer; on a `shortcut` match it deletes the
  trigger and pastes the expansion.
- UI lists are paged: fetch 100 rows, fetch more as selection/scroll nears the
  end.
- Keys: ↑/↓ navigate, Enter copy+close(+paste), ⌘Enter paste an image's OCR
  text instead of the image, Esc close, ⌘F focus search,
  ⌘1–⌘4 tabs (Classic/Shell/Favs/Media), ⌘P pin, ⌘S or ⌘B favorite,
  ⌘D or ⌥⌫ delete (⌥⌫ yields to delete-word while editing a non-empty
  search), ⌘R regex toggle (also the `.*` button). Hover selects a row;
  pointer-driven selection never auto-scrolls.
- Copy action: write to NSPasteboard, `touch(id:)`, close panel; when
  `paste.on_copy` is enabled, synthesize ⌘V into the frontmost app (Paster:
  CGEvent, AppleScript fallback, rate-limited Accessibility prompt). Pop sound
  + trackpad haptic feedback on success.
- Background workers (in app): `enforceLimits` + `applyRetention` at launch and
  every 5 minutes, hourly `vacuumIfNeeded`, thumbnail warmup — all detached,
  low priority, never on the main actor.
- Menu bar: template icon; menu = Open (shows current hotkey), Pause/Resume
  Monitoring, Recent (top 5), Settings…, Quit.
- Settings window (SwiftUI): limits per type with usage pills, shell history
  section, retention picker, hotkey preset picker, launch at login
  (SMAppService.mainApp), paste-on-select, snippets toggle, exclusions,
  backup/restore, and a live Health section (hotkey registration, snippet tap).

## CLI command surface

```
clap                                   open UI (notify app; launches it if found next to the CLI)
clap list [--images|--shell] [--favorites] [--tag <t>] [--limit N] [--offset N] [--json]
clap search <query> [--regex <pat>] [--type text|image|shell] [--tag <t>] [--limit N] [--offset N] [--json]
clap get <id> [--json]
clap copy <id>
clap add <text> | -                    insert entry (- reads stdin); alias: clap in
clap delete <id> | --text <text> | --regex <pat>
clap out [<id> | <exact text>]         alias of delete
clap pin <id> / clap unpin <id>
clap fav <id> / clap unfav <id>        aliases: favorite / unfavorite
clap tag add|remove|set <id> <tag...> / clap tag list [id] / clap tags
clap backup <dir> / clap restore <dir>
clap clear [--force]                   deletes ALL entries, pinned and favorites included
clap stats [--json]
clap config get [key] / clap config set <key> <value>
clap doctor
clap import maccy [--db <path>] [--dry-run]
clap import shell-history [--file <path>] [--dry-run]
clap pause / clap resume
```

- Command logic lives in `ClapCLIKit`; `Sources/ClapCLI/Main.swift` only calls
  `ClapCLI.main()`.
- Output: aligned plain text; single-line previews truncated to 60 chars with
  control chars stripped. `--json` on list/search/get/stats for scripting;
  entry JSON includes isPinned, isFavorite, tags, and shortcut.
- `copy`: read entry; text → NSPasteboard string; image → load file data, set
  as image data with correct type; `touch(id:)` for shell entries, or when the
  app isn't running (otherwise the app's monitor records the re-copy).
- All commands honor `--data-dir <path>` and `CLAP_DATA_DIR`.
- Exit codes: 0 ok, 1 not found / no match, 2 usage error.

## Testing & quality gates

Tests use a temp `CLAP_DATA_DIR` (via `withStore`) plus injected `now:` clock
and stub `OCREngine`. Cover: normalization, hashing stability, dedup (capture
same text twice → 1 row, recency bumped), recency ordering, count eviction,
byte-size eviction, pinned immunity, clear, search (terms, phrase, type
filter), regex search incl. invalid pattern error, ByteSize parse/format,
SearchQuery.parse, retention, OCR seam (mocked engine stores searchable text),
injected-clock determinism, text analysis (color/case/transform/JWT/epoch),
TextSummaries, ImageFormats, QR generation, JSON detection, color format
rendering, backup export/restore round-trip, CLI ArgParser/OutputFormatter,
and the app's AppState logic (hover-selection gate, tab→query mapping).

CI (`.github/workflows/ci.yml`) enforces three gates on every push:
`swift build -Xswiftc -warnings-as-errors`, full `swift test`, and a zero-
violation `swiftlint` pass (config in `.swiftlint.yml`). The UI is English-
only by design; SwiftUI text literals are already localization-ready should
translations ever be added.
