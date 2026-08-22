# clap — Architecture Contract

Native macOS clipboard manager. Local-first, no network, no telemetry.
This document is the binding contract between the three targets. Do not
deviate from public API signatures, schema, or IPC names without updating
this file.

## Targets

- `ClapCore` (library): SQLite storage, FTS5 search, normalization, hashing,
  dedup, LRU eviction, settings, image file store, stats, doctor checks, OCR
  text extraction, and shared text analysis (color/case/Base64/URL/JWT/epoch).
  **No AppKit/SwiftUI imports** (Foundation + CoreGraphics/ImageIO +
  UniformTypeIdentifiers + CryptoKit + Vision allowed — Vision powers the
  injectable `OCREngine`).
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

- `text.max_entries` (Int, default 100_000)
- `text.max_size` (bytes, Int64, default 52_428_800 = 50MB)
- `image.max_entries` (Int, default 500)
- `image.max_size` (bytes, Int64, default 104_857_600 = 100MB)
- `monitoring.paused` ("0"/"1", default "0")
- `exclusions` (JSON array of bundle ids, default `[]`)
- `retention.days` (Int, 0 = never, default 0)
- `launch_at_login` ("0"/"1", default "0")
- `paste.on_copy` ("0"/"1", default "1") — after a UI copy, synthesize Cmd+V
  into the frontmost app (needs Accessibility; copy-only fallback)

Size values accept human forms in CLI (`50MB`, `1GB`) — parse in ClapCore
(`ByteSize.parse/format`).

## ClapCore public API (implement exactly)

```swift
public enum EntryType: String, Codable, Sendable { case text, image }

public struct ClipboardEntry: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let type: EntryType
    public let content: String?        // normalized text
    public let imagePath: String?      // relative path under images/
    public let imageFormat: String?
    public let contentHash: String
    public let createdAt: Date
    public let lastUsedAt: Date
    public let sizeBytes: Int64
    public let isPinned: Bool
    public let useCount: Int
    public let sourceApp: String?
}

public struct SearchQuery: Sendable {
    public var text: String?           // FTS terms / phrase (quoted)
    public var regex: String?          // regex pattern (mutually exclusive with text)
    public var type: EntryType?        // nil = all
    public var pinnedOnly: Bool
    public var limit: Int
    public var offset: Int
    public init(text: String? = nil, regex: String? = nil, type: EntryType? = nil,
                pinnedOnly: Bool = false, limit: Int = 100, offset: Int = 0)
    /// Parses UI/CLI query syntax: bare terms, "quoted phrase",
    /// `regex:<pat>`, `type:text|image`. Unknown filters ignored.
    public static func parse(_ raw: String, limit: Int, offset: Int) -> SearchQuery
}

public struct StoreStats: Sendable {
    public let textCount: Int, imageCount: Int
    public let textBytes: Int64, imageBytes: Int64
    public let pinnedCount: Int
    public let eventsToday: Int, duplicatesAvoidedToday: Int
    public let oldestEntry: Date?
}

/// The single entry point. An actor so all DB access is serialized per process.
/// Multi-process safety comes from SQLite WAL + busy_timeout.
public actor ClipboardStore {
    public init(dataDir: URL? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                ocr: any OCREngine = VisionOCREngine()) throws
    public nonisolated let dataDir: URL

    // Capture path (fast): normalize → hash → indexed lookup → insert or touch.
    // Returns the entry and whether it was a duplicate (touched, not inserted).
    // OCR runs OUTSIDE the write transaction and off the actor executor.
    @discardableResult
    public func captureText(_ raw: String, sourceApp: String?) throws -> (entry: ClipboardEntry, wasDuplicate: Bool)?  // nil if empty after normalization
    @discardableResult
    public func captureImage(data: Data, format: String, sourceApp: String?) async throws -> (entry: ClipboardEntry, wasDuplicate: Bool)?

    // Queries
    public func list(type: EntryType?, limit: Int, offset: Int) throws -> [ClipboardEntry]
    public func search(_ query: SearchQuery) throws -> [ClipboardEntry]
    public func entry(id: Int64) throws -> ClipboardEntry?
    public func count(type: EntryType?) throws -> Int

    // Mutations
    public func touch(id: Int64) throws                 // bump last_used_at + use_count
    public func delete(id: Int64) throws -> Bool
    public func deleteMatching(text: String) throws -> Int      // exact normalized text
    public func deleteMatching(regexPattern: String) throws -> Int
    public func setPinned(_ pinned: Bool, id: Int64) throws -> Bool
    public func clearAll() throws -> Int                 // returns removed count; also wipes image files

    // Maintenance (called by background workers / CLI)
    public func enforceLimits() throws -> Int            // LRU eviction, returns evicted count
    public func applyRetention() throws -> Int
    public func vacuumIfNeeded() throws

    // Image helpers
    public func imageFileURL(for entry: ClipboardEntry) -> URL?
    public func thumbnailURL(for entry: ClipboardEntry) throws -> URL?  // generates lazily

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
    /// Compiles NSRegularExpression; evaluates with a match-count/length guard.
    /// Never throws at match time; invalid pattern → .invalidPattern error on compile.
    public static func compile(_ pattern: String) throws -> NSRegularExpression
}
public enum TextSummaries {
    public static func singleLine(_ s: String, maxChars: Int) -> String   // collapse ws/control chars, "…" truncate
    public static func relativeTime(_ date: Date, now: Date) -> String    // "now", "5m", "2h", "3d", else "yyyy-MM-dd"
}
public enum ImageFormats {
    public static func uti(forFormat format: String) -> String?           // 'gif' → 'com.compuserve.gif'
}
public enum ConfigKey { /* typed constants for every config-table key */ }

/// Injectable OCR seam (Vision-backed default; tests use stubs).
public protocol OCREngine: Sendable {
    func recognizeText(from imageData: Data) async -> String?
}
public struct VisionOCREngine: OCREngine {}

// Shared clipboard content analysis (used by app UI and available to CLI):
public struct ParsedColor: Sendable, Equatable {}   // r/g/b/a components
public enum ColorParser { public static func parse(_ raw: String?) -> ParsedColor? }
public enum CaseConverter { /* camel/pascal/snake/kebab/constant/upper/lower/title */ }
public enum TextTransformer { /* Base64 + URL encode/decode with length guards */ }
public struct JWTData: Sendable, Equatable { public static func parse(_ text: String?) -> JWTData? }
public struct EpochData: Sendable, Equatable { public static func parse(_ text: String?) -> EpochData? }

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
- Eviction: per-category count and byte limits applied to NON-PINNED rows only
  (pinned entries live outside the budget — counting them would let enough
  pinned rows permanently starve new captures); delete lowest `last_used_at`
  where `is_pinned = 0`; entries larger than the whole category budget are
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
- Hotkey: Carbon `RegisterEventHotKey` (cmd+shift, key `B` = kVK_ANSI_B). No
  accessibility permission needed.
- Panel: borderless `NSPanel` (floating, `.nonactivatingPanel`, `.resizable`,
  min 480×320), hosts SwiftUI. Movable by background drag, resizable at the
  edges; the user-chosen frame is debounce-persisted to config key
  `ui.panel_frame` and restored on every open (fallback: centered ~720×480 on
  the mouse's screen when unset or the saved display is gone). Esc closes.
  Opens with search focused.
- Preview: a non-key child `NSPanel` follows the selection (200 ms debounce):
  placed right of the panel, else left, else below, else above. Shows
  scrollable text / fitted image plus metadata (id + transient-marked Copy ID
  button, type, size, created/last-used, use count, source app name, pin).
  Hidden with the panel; repositioned on move/resize.
- Pasteboard monitor: poll `NSPasteboard.general.changeCount` every 150 ms on a
  background task; on change, read text/image off the main thread, skip when
  paused, skip when frontmost app is in exclusions, skip transient/concealed
  pasteboard types (`org.nspasteboard.TransientType`,
  `org.nspasteboard.ConcealedType`), then call `store.captureText/Image`.
  When clap itself writes to the pasteboard (copy action), pre-bump the
  expected changeCount so its own write is only used to touch recency, not
  re-captured as new.
- UI lists are paged: fetch 100 rows, fetch more as selection/scroll nears the
  end. Media tab = LazyVGrid of thumbnails.
- Keys: ↑/↓ navigate, Enter copy+close, Esc close, Cmd+F focus search,
  Cmd+1-Cmd+4 tabs, Cmd+P pin toggle, Cmd+D or Option+Delete delete (the
  latter yields to delete-word while editing a non-empty search), hover
  selects a row (pointer-driven selection never auto-scrolls), Cmd+R
  regex-mode toggle
  (also a `.*` button beside the search field; in regex mode the whole query
  is the pattern). Number keys ①-⑨ shown for the first 9 rows; pressing 1-9
  copies that row.
- Copy action: write to NSPasteboard (declare types properly), `touch(id:)`,
  close panel; when `paste.on_copy` is enabled, then synthesize Cmd+V into the
  frontmost app (Paster, CGEvent; requires Accessibility, degrades to
  copy-only with a one-time system prompt).
- Background workers (in app): periodic `enforceLimits`, `applyRetention`,
  thumbnail pre-generation, `vacuumIfNeeded` — all via detached low-priority
  tasks, never on the main actor.
- Menu bar: clipboard icon; menu = Open (Cmd+Shift+V hint), Pause/Resume
  Monitoring (reflects state), Recent (top 5 text previews, truncated 40 chars),
  Settings…, Quit.
- Settings window (SwiftUI): limits (entries + sizes with MB fields), retention
  picker, launch at login (SMAppService.mainApp), exclusions list (add via
  bundle id text field + list of running apps), pause toggle.

## CLI command surface

```
clap                       open UI (notify app)
clap list [--images] [--limit N] [--offset N]
clap search <query> [--regex <pat>] [--type text|image] [--limit N]
clap get <id>
clap copy <id>
clap delete <id> | --text <text> | --regex <pat>
clap out [<id> | <exact text>]     alias of delete
clap pin <id> / clap unpin <id>
clap clear [--force]
clap stats
clap config get [key] / clap config set <key> <value>
clap doctor
clap import maccy [--db <path>] [--dry-run]
clap pause / clap resume
```

- Output: aligned plain text; single-line previews truncated to 60 chars with
  control chars stripped. `--json` flag on list/search/get/stats for scripting.
- `copy`: read entry; text → NSPasteboard string; image → load file data, set
  as image data with correct type; then `touch(id:)` and post `storeChanged`.
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
TextSummaries, ImageFormats, CLI ArgParser/OutputFormatter, and the app's
AppState logic (hover-selection gate, tab→query mapping).

CI (`.github/workflows/ci.yml`) enforces three gates on every push:
`swift build -Xswiftc -warnings-as-errors`, full `swift test`, and a zero-
violation `swiftlint` pass (config in `.swiftlint.yml`). The UI is English-
only by design; SwiftUI text literals are already localization-ready should
translations ever be added.
