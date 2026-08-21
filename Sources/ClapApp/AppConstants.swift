import Foundation

/// Design tokens for ClapApp: timings and recurring style alphas in one
/// place so behavior tuning never requires grepping for nanoseconds.
enum Timing {
    /// Search-as-you-type debounce.
    static let searchDebounceNanos: UInt64 = 150_000_000
    /// Pasteboard polling cadence.
    static let pasteboardPollNanos: UInt64 = 150_000_000
    static let shellHistoryPollNanos: UInt64 = 2_000_000_000
    /// Panel frame persistence debounce (windowDidMove fires continuously).
    static let frameSaveDebounceNanos: UInt64 = 300_000_000
    /// Delay between closing the panel and synthesizing Cmd+V.
    static let pasteDelayNanos: UInt64 = 100_000_000
    /// "Copied" button label reset.
    static let copiedResetNanos: UInt64 = 1_500_000_000
    /// Transient error banner auto-dismiss.
    static let errorBannerResetNanos: UInt64 = 4_000_000_000
    /// Settings save-failure banner auto-dismiss.
    static let saveErrorResetNanos: UInt64 = 5_000_000_000
}

/// Recurring translucency values. One-off contextual alphas stay inline.
enum AppAlpha {
    enum Fill {
        static let subtle: Double = 0.04
        static let soft: Double = 0.06
        static let searchField: Double = 0.05
        static let rowSelected: Double = 0.36
        static let pillSelectedCount: Double = 0.20
    }
    enum Stroke {
        static let hairline: Double = 0.08
        static let panelBorder: Double = 0.12
        static let rowSelectedBorder: Double = 0.45
        static let swatch: Double = 0.20
    }
    enum Hover {
        static let fill: Double = 0.09
        static let strongFill: Double = 0.12
    }
}
