import Foundation

/// Config table keys. Values are strings; typed accessors live in Settings
/// layers. Single source of truth for writer/reader pairs across targets.
public enum ConfigKey {
    public static let textMaxEntries = "text.max_entries"
    public static let textMaxSize = "text.max_size"
    public static let imageMaxEntries = "image.max_entries"
    public static let imageMaxSize = "image.max_size"
    public static let monitoringPaused = "monitoring.paused"
    public static let exclusions = "exclusions"
    public static let retentionDays = "retention.days"
    public static let launchAtLogin = "launch_at_login"
    public static let pasteOnCopy = "paste.on_copy"
    public static let shellEnabled = "shell.enabled"
    public static let shellMaxEntries = "shell.max_entries"
    public static let shellMaxSize = "shell.max_size"
    public static let shellHistfile = "shell.histfile"
    public static let snippetsEnabled = "snippets.enabled"
    public static let uiPanelFrame = "ui.panel_frame"
    public static let uiHotkey = "ui.hotkey"
    public static let shellInitialImported = "shell.initial_imported"
}

enum CoreConstants {
    /// Clipboard data is sensitive: owner-only on everything we create.
    static let ownerOnlyDirectoryAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    static let ownerOnlyFileAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]

    /// Shared batch/chunk size for eviction, retention, regex scans and
    /// IN-clause deletes: bounds memory without hammering SQLite.
    static let sqlBatchSize = 500

    static let thumbnailMaxPixelSize = 400
    static let vacuumFreelistPageThreshold: Int64 = 1000
    static let minDiskFreeBytes: Int64 = 200 * 1024 * 1024
    static let secondsPerDay: Double = 86_400
    static let tagConcatSeparator = "|||"

    static let busyTimeoutMilliseconds = 3000
}
