import AppKit
import SwiftUI
import ClapCore
import os

/// Main-actor view model backing the panel UI. All store calls hop to the
/// ClipboardStore actor and results are marshaled back to the main actor.
@MainActor
final class AppState: ObservableObject {

    enum Tab: Int {
        case classic
        case media
        case shell

        /// Entry types this tab shows. Classic = clipboard only (text+image);
        /// shell commands live in their own tab.
        var types: Set<EntryType> {
            switch self {
            case .classic: return [.text, .image]
            case .media: return [.image]
            case .shell: return [.shell]
            }
        }
    }

    let store: ClipboardStore
    let monitor: PasteboardMonitor

    /// Set by PanelController — closes the panel.
    var onCloseRequest: (() -> Void)?
    /// Set by AppDelegate — opens the Settings window.
    var onOpenSettings: (() -> Void)?

    @Published var tab: Tab = .classic {
        didSet {
            guard oldValue != tab else { return }
            selectedID = nil
            reload()
        }
    }
    @Published var rawQuery: String = "" {
        didSet {
            guard !suppressSearchTrigger, oldValue != rawQuery else { return }
            scheduleSearch()
        }
    }
    /// Regex mode (⌘R / the .* button): the whole query is a regex pattern.
    /// Sticky for the app's lifetime, not persisted.
    @Published var regexMode = false {
        didSet {
            guard oldValue != regexMode else { return }
            if !trimmedQuery.isEmpty { reload() }
        }
    }
    @Published private(set) var pinned: [ClipboardEntry] = []
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published var selectedID: Int64?
    @Published private(set) var searchError: String?
    /// Incremented to move keyboard focus into the search field.
    @Published var searchFocusToken = 0

    static let pageSize = 100

    private var suppressSearchTrigger = false
    private var generation = 0
    private var fetchedCount = 0          // rows fetched from the store (pre-dedup)
    private var reachedEnd = false
    private var isLoadingMore = false
    private var searchDebounceTask: Task<Void, Never>?
    private let thumbnailCache = NSCache<NSNumber, NSImage>()
    private let logger = Logger(subsystem: "com.spongycode.clap", category: "ui")

    init(store: ClipboardStore, monitor: PasteboardMonitor) {
        self.store = store
        self.monitor = monitor
        thumbnailCache.countLimit = 300
    }

    // MARK: - Derived state

    var trimmedQuery: String { rawQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The pinned section is only shown in the default (no-search) Classic list.
    var showsPinnedSection: Bool { tab == .classic && trimmedQuery.isEmpty && !pinned.isEmpty }

    /// All rows in display order — selection navigation operates on this.
    var flatRows: [ClipboardEntry] { showsPinnedSection ? pinned + entries : entries }

    var selectedEntry: ClipboardEntry? { flatRows.first { $0.id == selectedID } }

    // MARK: - Lifecycle

    /// Called right before the panel is shown: reset search, reload page one.
    func panelWillShow() {
        searchDebounceTask?.cancel()
        suppressSearchTrigger = true
        rawQuery = ""
        suppressSearchTrigger = false
        selectedID = nil
        reload()
    }

    // MARK: - Loading

    private func scheduleSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// Builds the SearchQuery for the current raw query, or nil when the
    /// default (unfiltered) list should be shown.
    private func buildQuery(offset: Int) -> SearchQuery? {
        let raw = trimmedQuery
        guard !raw.isEmpty else { return nil }
        var query: SearchQuery
        if regexMode {
            query = SearchQuery(regex: raw, limit: Self.pageSize, offset: offset)
        } else {
            query = SearchQuery.parse(raw, limit: Self.pageSize, offset: offset)
        }
        // The tab constrains types unless the query already used `type:`.
        if query.type == nil { query.types = tab.types }
        return query
    }

    /// Reloads page one for the current tab + query.
    func reload() {
        generation += 1
        let gen = generation
        let currentTab = tab
        let query = buildQuery(offset: 0)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var newPinned: [ClipboardEntry] = []
                let fetched: [ClipboardEntry]
                if let query {
                    fetched = try await self.store.search(query)
                } else {
                    if currentTab == .classic {
                        newPinned = try await self.store.search(SearchQuery(pinnedOnly: true, limit: 50))
                        fetched = try await self.store.search(SearchQuery(types: [.text, .image], limit: Self.pageSize, offset: 0))
                    } else if currentTab == .media {
                        fetched = try await self.store.list(type: .image, limit: Self.pageSize, offset: 0)
                    } else {
                        fetched = try await self.store.list(type: .shell, limit: Self.pageSize, offset: 0)
                    }
                }
                guard gen == self.generation else { return }
                self.searchError = nil
                self.pinned = newPinned
                self.fetchedCount = fetched.count
                self.reachedEnd = fetched.count < Self.pageSize
                if newPinned.isEmpty {
                    self.entries = fetched
                } else {
                    let pinnedIDs = Set(newPinned.map(\.id))
                    self.entries = fetched.filter { !pinnedIDs.contains($0.id) }
                }
                self.isLoadingMore = false
                if self.selectedEntry == nil {
                    self.selectedID = self.flatRows.first?.id
                }
            } catch {
                guard gen == self.generation else { return }
                if case ClapCoreError.invalidPattern = error {
                    self.searchError = "Invalid regular expression"
                } else {
                    self.searchError = "Search failed"
                    self.logger.error("search failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Fetches the next page when `entry` is near the end of the loaded list.
    func loadMoreIfNeeded(_ entry: ClipboardEntry) {
        guard !reachedEnd, !isLoadingMore else { return }
        guard let index = entries.firstIndex(where: { $0.id == entry.id }),
              index >= entries.count - 20 else { return }
        isLoadingMore = true
        let gen = generation
        let currentTab = tab
        let offset = fetchedCount
        let query = buildQuery(offset: offset)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLoadingMore = false }
            do {
                let fetched: [ClipboardEntry]
                if let query {
                    fetched = try await self.store.search(query)
                } else if currentTab == .classic {
                    fetched = try await self.store.search(SearchQuery(types: [.text, .image], limit: Self.pageSize, offset: offset))
                } else if currentTab == .media {
                    fetched = try await self.store.list(type: .image, limit: Self.pageSize, offset: offset)
                } else {
                    fetched = try await self.store.list(type: .shell, limit: Self.pageSize, offset: offset)
                }
                guard gen == self.generation else { return }
                self.fetchedCount += fetched.count
                self.reachedEnd = fetched.count < Self.pageSize
                var known = Set(self.entries.map(\.id))
                known.formUnion(self.pinned.map(\.id))
                self.entries += fetched.filter { !known.contains($0.id) }
            } catch {
                self.logger.error("page load failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Selection / keyboard actions

    /// True when the current selection came from the mouse (hover/click).
    /// The lists only auto-scroll to keyboard-driven selection — scrolling to
    /// a hovered row would yank the list around under the cursor.
    private(set) var selectionCameFromPointer = false

    func selectFromPointer(_ id: Int64) {
        selectionCameFromPointer = true
        selectedID = id
    }

    func moveSelection(_ delta: Int) {
        let rows = flatRows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedID } ?? -1
        let next = min(max(current + delta, 0), rows.count - 1)
        selectionCameFromPointer = false
        selectedID = rows[next].id
        loadMoreIfNeeded(rows[next])
    }

    func copySelected() {
        guard let entry = selectedEntry else { return }
        copy(entry)
    }

    func togglePinSelected() {
        guard let entry = selectedEntry else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.store.setPinned(!entry.isPinned, id: entry.id)
            IPC.post(.storeChanged)
            self.reload()
        }
    }

    func deleteSelected() {
        guard let entry = selectedEntry else { return }
        let rows = flatRows
        let index = rows.firstIndex { $0.id == entry.id } ?? 0
        let nextID: Int64? = rows.indices.contains(index + 1)
            ? rows[index + 1].id
            : (index > 0 ? rows[index - 1].id : nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.store.delete(id: entry.id)
            self.selectedID = nextID
            IPC.post(.storeChanged)
            self.reload()
        }
    }

    func delete(_ entry: ClipboardEntry) {
        selectedID = entry.id
        deleteSelected()
    }

    func togglePin(_ entry: ClipboardEntry) {
        selectedID = entry.id
        togglePinSelected()
    }

    // MARK: - Copy to pasteboard

    /// Writes the entry to NSPasteboard.general. The monitor is told about
    /// the expected self-inflicted change first so it only bumps recency
    /// instead of re-capturing.
    func copy(_ entry: ClipboardEntry) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch entry.type {
            case .text:
                await self.monitor.expectSelfChange(entryID: entry.id)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(entry.content ?? "", forType: .string)
                await self.monitor.confirmSelfChange(changeCount: pasteboard.changeCount)
            case .shell:
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(entry.content ?? "", forType: .string)
                try? await self.store.touch(id: entry.id)
            case .image:
                // Load the full image data first: only tell the monitor once
                // we know the write will actually happen.
                guard let url = await self.store.imageFileURL(for: entry) else { return }
                let data = await Task.detached(priority: .userInitiated) {
                    try? Data(contentsOf: url)
                }.value
                guard let data else {
                    self.logger.error("copy failed: image file missing for entry \(entry.id, privacy: .public)")
                    return
                }
                await self.monitor.expectSelfChange(entryID: entry.id)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                switch entry.imageFormat?.lowercased() {
                case "png":
                    pasteboard.setData(data, forType: .png)
                case "tiff", "tif":
                    pasteboard.setData(data, forType: .tiff)
                case "jpeg", "jpg":
                    pasteboard.setData(data, forType: NSPasteboard.PasteboardType("public.jpeg"))
                default:
                    // Unknown format: convert through NSImage to TIFF.
                    if let tiff = NSImage(data: data)?.tiffRepresentation {
                        pasteboard.setData(tiff, forType: .tiff)
                    } else {
                        pasteboard.setData(data, forType: .tiff)
                    }
                }
                await self.monitor.confirmSelfChange(changeCount: pasteboard.changeCount)
            }
            IPC.post(.storeChanged)
            self.onCloseRequest?()

            // Maccy-style paste-on-select: the panel never activated clap, so
            // the app the user came from still has key focus. Small delay so
            // the panel is gone and the pasteboard write has settled before
            // the synthetic Cmd+V lands.
            let pasteEnabled = ((try? await self.store.config("paste.on_copy")) ?? "1") == "1"
            if pasteEnabled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                Paster.pasteToFrontmostApp()
            }
        }
    }

    // MARK: - Thumbnails

    /// Loads (and lazily generates) the thumbnail for an image entry,
    /// cached in a small NSCache.
    func thumbnail(for entry: ClipboardEntry) async -> NSImage? {
        let key = NSNumber(value: entry.id)
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let url = try? await store.thumbnailURL(for: entry) else { return nil }
        let image = await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value
        if let image { thumbnailCache.setObject(image, forKey: key) }
        return image
    }
}
