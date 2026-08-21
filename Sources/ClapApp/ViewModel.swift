import AppKit
import SwiftUI
import ClapCore
import os

/// Main-actor view model backing the panel UI. All store calls hop to the
/// ClipboardStore actor and results are marshaled back to the main actor.
@MainActor
final class AppState: ObservableObject {

    enum Tab: String, CaseIterable {
        case classic, media, shell, favs

        /// Entry types this tab shows. Classic = clipboard only (text+image);
        /// shell commands live in their own tab; favs shows all pinned entries.
        var types: Set<EntryType> {
            switch self {
            case .classic: return [.text, .image]
            case .media: return [.image]
            case .shell: return [.shell]
            case .favs: return [.text, .image, .shell]
            }
        }
    }

    let store: ClipboardStore
    let monitor: PasteboardMonitor

    /// Set by PanelController — closes the panel.
    var onCloseRequest: (() -> Void)?
    /// Set by AppDelegate — opens the Settings window.
    var onOpenSettings: (() -> Void)?

    @Published private(set) var tab: Tab = .classic
    /// Search text as typed. Mutate through `queryChanged(_:)` so the
    /// debounced search fires; direct writes stay silent (panel reset).
    @Published private(set) var rawQuery: String = ""
    /// Regex mode (⌘R / the .* button): the whole query is a regex pattern.
    /// Sticky for the app's lifetime, not persisted.
    @Published private(set) var regexMode = false
    @Published private(set) var pinned: [ClipboardEntry] = []
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published var selectedID: Int64?
    @Published private(set) var searchError: String?
    /// Selected tag in Favorites / Pinboards tab (nil = All)
    @Published private(set) var selectedTag: String?
    /// Available tags across the store with their entry counts
    @Published private(set) var availableTags: [(tag: String, count: Int)] = []
    /// Incremented to move keyboard focus into the search field.
    @Published var searchFocusToken = 0
    /// Last failed store mutation, shown as a dismissable banner. Auto-clears.
    @Published private(set) var transientError: String?

    func dismissTransientError() {
        transientError = nil
    }

    // MARK: - UI intents (explicit state transitions)

    func selectTab(_ newTab: Tab) {
        guard tab != newTab else { return }
        tab = newTab
        selectedID = nil
        reload()
    }

    func selectTag(_ tag: String?) {
        guard selectedTag != tag else { return }
        selectedTag = tag
        selectedID = nil
        reload()
    }

    func setRegexMode(_ enabled: Bool) {
        guard regexMode != enabled else { return }
        regexMode = enabled
        if !trimmedQuery.isEmpty { reload() }
    }

    /// Live search-text updates from the field; debounced reload.
    func queryChanged(_ newValue: String) {
        guard rawQuery != newValue else { return }
        rawQuery = newValue
        scheduleSearch()
    }

    static let pageSize = 100

    private var generation = 0
    private var fetchedCount = 0          // rows fetched from the store (pre-dedup)
    private var reachedEnd = false
    private var isLoadingMore = false
    private var searchDebounceTask: Task<Void, Never>?
    private var transientErrorTask: Task<Void, Never>?
    let thumbnailCache = NSCache<NSNumber, NSImage>()
    let logger = Logger(subsystem: ClapIdentity.bundleID, category: "ui")

    init(store: ClipboardStore, monitor: PasteboardMonitor) {
        self.store = store
        self.monitor = monitor
        thumbnailCache.countLimit = 300
    }

    /// Runs a store mutation, surfacing failures instead of swallowing them:
    /// logs at fault level and shows a transient banner in the UI.
    func perform(_ label: String, _ op: () async throws -> Void) async {
        do {
            try await op()
        } catch {
            logger.fault("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            showTransientError(String(localized: "\(label) failed"))
        }
    }

    func showTransientError(_ message: String) {
        transientError = message
        transientErrorTask?.cancel()
        transientErrorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Timing.errorBannerResetNanos)
            guard !Task.isCancelled else { return }
            self?.transientError = nil
        }
    }

    // MARK: - Derived state

    var trimmedQuery: String { rawQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The pinned section is only shown in the default (no-search) Classic list.
    var showsPinnedSection: Bool { tab == .classic && trimmedQuery.isEmpty && !pinned.isEmpty }

    /// All rows in display order — selection navigation operates on this.
    var flatRows: [ClipboardEntry] { showsPinnedSection ? pinned + entries : entries }

    var selectedEntry: ClipboardEntry? { flatRows.first { $0.id == selectedID } }

    // MARK: - Lifecycle

    /// Called right before the panel is shown: reset search, reload page one,
    /// and disarm hover selection until the pointer moves again.
    func panelWillShow() {
        searchDebounceTask?.cancel()
        rawQuery = ""
        selectedID = nil
        pointerArmed = false
        pendingPointerEntryID = nil
        reload()
    }

    // MARK: - Loading

    private func scheduleSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Timing.searchDebounceNanos)
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
        if tab == .favs {
            if let selectedTag {
                query.tag = selectedTag
            } else {
                query.favoriteOnly = true
            }
        }
        return query
    }

    /// The default (no-search) query for a tab, or nil when the tab needs
    /// special handling (Classic's pinned section). Pure and internal so the
    /// tab→query mapping is unit-testable.
    static func defaultQuery(tab: Tab, tag: String?, offset: Int) -> SearchQuery? {
        switch tab {
        case .classic:
            return SearchQuery(types: [.text, .image], limit: Self.pageSize, offset: offset)
        case .media:
            return SearchQuery(type: .image, limit: Self.pageSize, offset: offset)
        case .shell:
            return SearchQuery(type: .shell, limit: Self.pageSize, offset: offset)
        case .favs:
            if let tag {
                return SearchQuery(tag: tag, limit: Self.pageSize, offset: offset)
            }
            return SearchQuery(favoriteOnly: true, limit: Self.pageSize, offset: offset)
        }
    }

    /// Reloads page one for the current tab + query.
    func reload() {
        generation += 1
        let gen = generation
        let currentTab = tab
        let currentTag = selectedTag
        let query = buildQuery(offset: 0)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var newPinned: [ClipboardEntry] = []
                let fetched: [ClipboardEntry]
                if let query {
                    fetched = try await self.store.search(query)
                } else if currentTab == .classic {
                    newPinned = try await self.store.search(SearchQuery(pinnedOnly: true, limit: 50))
                    fetched = try await self.store.search(
                        Self.defaultQuery(tab: currentTab, tag: currentTag, offset: 0)!)
                } else {
                    fetched = try await self.store.search(
                        Self.defaultQuery(tab: currentTab, tag: currentTag, offset: 0)!)
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
                self.refreshSnippets()
                self.refreshTags()
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
        let currentTag = selectedTag
        let offset = fetchedCount
        let query = buildQuery(offset: offset)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLoadingMore = false }
            do {
                let fetched: [ClipboardEntry]
                if let query {
                    fetched = try await self.store.search(query)
                } else {
                    fetched = try await self.store.search(
                        Self.defaultQuery(tab: currentTab, tag: currentTag, offset: offset)!)
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

    /// Hover-selection gate: when the panel opens under a stationary cursor,
    /// the row's tracking area fires immediately and would steal the
    /// selection from the newest entry (breaking blind paste). Hover may not
    /// change the selection until the pointer physically moves after show().
    private(set) var pointerArmed = false

    /// The row the pointer was over when the panel opened (captured from the
    /// initial hover event) or most recently entered while disarmed. Applied
    /// the moment the pointer moves, so a tiny movement selects the row
    /// already under the cursor — no leave/re-enter needed.
    private var pendingPointerEntryID: Int64?

    func armPointer() {
        guard !pointerArmed else { return }
        pointerArmed = true
        if let pending = pendingPointerEntryID {
            selectionCameFromPointer = true
            selectedID = pending
        }
    }

    /// Row hover tracking. While disarmed the hovered row is only remembered;
    /// once armed it becomes the selection immediately.
    func hoverChanged(_ id: Int64, hovering: Bool) {
        if hovering {
            pendingPointerEntryID = id
            guard pointerArmed else { return }
            selectionCameFromPointer = true
            selectedID = id
        } else if pendingPointerEntryID == id {
            pendingPointerEntryID = nil
        }
    }

    func selectFromPointer(_ id: Int64) {
        hoverChanged(id, hovering: true)
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
            await self.perform("Pin") { try await self.store.setPinned(!entry.isPinned, id: entry.id) }
            IPC.post(.storeChanged)
            self.reload()
        }
    }

    func toggleFavoriteSelected() {
        guard let entry = selectedEntry else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.perform("Favorite") { try await self.store.setFavorite(!entry.isFavorite, id: entry.id) }
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
            await self.perform("Delete") { try await self.store.delete(id: entry.id) }
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

    func toggleFavorite(_ entry: ClipboardEntry) {
        selectedID = entry.id
        toggleFavoriteSelected()
    }

    func promptSetShortcut(_ entry: ClipboardEntry) {
        SnippetWindowController.shared.show(for: entry, state: self)
    }

    func setShortcut(_ shortcut: String?, for entry: ClipboardEntry) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.perform("Shortcut") { try await self.store.setShortcut(shortcut, id: entry.id) }
            IPC.post(.storeChanged)
            self.reload()
            self.refreshSnippets()
        }
    }

    func refreshSnippets() {
        Task { [weak self] in
            guard let self else { return }
            let all = (try? await self.store.allShortcuts()) ?? [:]
            SnippetExpander.shared.updateSnippets(all)
        }
    }

    func refreshTags() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.availableTags = (try? await self.store.allTags()) ?? []
        }
    }

    func promptManageTags(_ entry: ClipboardEntry) {
        TagWindowController.shared.show(for: entry, state: self)
    }

    func addTag(_ tag: String, to entry: ClipboardEntry) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.perform("Add tag") { try await self.store.addTag(tag, entryID: entry.id) }
            IPC.post(.storeChanged)
            self.reload()
            self.refreshTags()
        }
    }

    func removeTag(_ tag: String, from entry: ClipboardEntry) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.perform("Remove tag") { try await self.store.removeTag(tag, entryID: entry.id) }
            IPC.post(.storeChanged)
            self.reload()
            self.refreshTags()
        }
    }

    func setTags(_ tags: [String], for entry: ClipboardEntry) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.perform("Save tags") { try await self.store.setTags(tags, entryID: entry.id) }
            IPC.post(.storeChanged)
            self.reload()
            self.refreshTags()
        }
    }
}
