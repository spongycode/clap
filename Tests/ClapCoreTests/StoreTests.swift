import Foundation
import Testing
@testable import ClapCore

@Suite("Capture & dedup")
struct CaptureTests {
    @Test func captureInsertsNormalizedText() async throws {
        try await withStore { store, _ in
            let result = try #require(try await store.captureText("  hello world \n", sourceApp: "com.test.app"))
            #expect(result.wasDuplicate == false)
            #expect(result.entry.content == "hello world")
            #expect(result.entry.type == .text)
            #expect(result.entry.sizeBytes == Int64("hello world".utf8.count))
            #expect(result.entry.useCount == 1)
            #expect(result.entry.sourceApp == "com.test.app")
            #expect(result.entry.contentHash == ContentHasher.textHash("hello world"))
            let count = try await store.count(type: .text)
            #expect(count == 1)
        }
    }

    @Test func emptyAfterNormalizationReturnsNil() async throws {
        try await withStore { store, _ in
            let result = try await store.captureText("   \n\t  ", sourceApp: nil)
            #expect(result == nil)
            let count = try await store.count(type: nil)
            #expect(count == 0)
        }
    }

    @Test func duplicateTextTouchesInsteadOfInserting() async throws {
        try await withStore { store, _ in
            let first = try #require(try await store.captureText("dup me", sourceApp: nil))
            // Backdate so the recency bump is observable.
            try await store._test_setTimestamps(id: first.entry.id,
                                                lastUsedAt: Date(timeIntervalSinceNow: -100))
            let second = try #require(try await store.captureText("  dup me  ", sourceApp: nil))
            #expect(second.wasDuplicate == true)
            #expect(second.entry.id == first.entry.id)
            #expect(second.entry.useCount == 2)
            #expect(second.entry.lastUsedAt > Date(timeIntervalSinceNow: -50))
            let count = try await store.count(type: .text)
            #expect(count == 1)

            let stats = try await store.stats()
            #expect(stats.eventsToday == 2)
            #expect(stats.duplicatesAvoidedToday == 1)
        }
    }
}

@Suite("Listing & recency")
struct ListTests {
    @Test func listOrdersByRecency() async throws {
        try await withStore { store, _ in
            let a = try #require(try await store.captureText("alpha", sourceApp: nil)).entry
            let b = try #require(try await store.captureText("beta", sourceApp: nil)).entry
            let c = try #require(try await store.captureText("gamma", sourceApp: nil)).entry
            try await store._test_setTimestamps(id: a.id, lastUsedAt: Date(timeIntervalSinceNow: -30))
            try await store._test_setTimestamps(id: b.id, lastUsedAt: Date(timeIntervalSinceNow: -20))
            try await store._test_setTimestamps(id: c.id, lastUsedAt: Date(timeIntervalSinceNow: -10))

            var listed = try await store.list(type: nil, limit: 100, offset: 0)
            #expect(listed.map(\.content) == ["gamma", "beta", "alpha"])

            // touch bumps recency to the front
            try await store.touch(id: a.id)
            listed = try await store.list(type: nil, limit: 100, offset: 0)
            #expect(listed.map(\.content) == ["alpha", "gamma", "beta"])
            #expect(listed[0].useCount == 2)
        }
    }

    @Test func listPaginationAndTypeFilter() async throws {
        try await withStore { store, _ in
            for i in 0..<5 {
                let e = try #require(try await store.captureText("item \(i)", sourceApp: nil)).entry
                try await store._test_setTimestamps(id: e.id, lastUsedAt: Date(timeIntervalSinceNow: Double(i - 10)))
            }
            _ = try #require(try await store.captureImage(data: makePNG(), format: "png", sourceApp: nil))

            let totalCount = try await store.count(type: nil)
            let textCount = try await store.count(type: .text)
            let imageCount = try await store.count(type: .image)
            #expect(totalCount == 6)
            #expect(textCount == 5)
            #expect(imageCount == 1)

            let page = try await store.list(type: .text, limit: 2, offset: 1)
            #expect(page.count == 2)
            #expect(page.map(\.content) == ["item 3", "item 2"])

            let images = try await store.list(type: .image, limit: 100, offset: 0)
            #expect(images.count == 1)
            #expect(images[0].type == .image)
        }
    }

    @Test func entryByIDAndDelete() async throws {
        try await withStore { store, _ in
            let e = try #require(try await store.captureText("find me", sourceApp: nil)).entry
            let fetched = try #require(try await store.entry(id: e.id))
            #expect(fetched == e)
            let missing = try await store.entry(id: 99_999)
            #expect(missing == nil)

            let firstDelete = try await store.delete(id: e.id)
            let secondDelete = try await store.delete(id: e.id)
            #expect(firstDelete == true)
            #expect(secondDelete == false)
            let count = try await store.count(type: nil)
            #expect(count == 0)
        }
    }

    @Test func pinAndUnpin() async throws {
        try await withStore { store, _ in
            let e = try #require(try await store.captureText("pin me", sourceApp: nil)).entry
            #expect(e.isPinned == false)
            let pinResult = try await store.setPinned(true, id: e.id)
            #expect(pinResult == true)
            let pinned = try #require(try await store.entry(id: e.id))
            #expect(pinned.isPinned == true)
            let unpinResult = try await store.setPinned(false, id: e.id)
            #expect(unpinResult == true)
            let missingResult = try await store.setPinned(true, id: 12_345)
            #expect(missingResult == false)
        }
    }

    @Test func favoriteAndUnfavorite() async throws {
        try await withStore { store, _ in
            let e = try #require(try await store.captureText("favorite me", sourceApp: nil)).entry
            #expect(e.isFavorite == false)
            let favResult = try await store.setFavorite(true, id: e.id)
            #expect(favResult == true)
            let fav = try #require(try await store.entry(id: e.id))
            #expect(fav.isFavorite == true)
            let unfavResult = try await store.setFavorite(false, id: e.id)
            #expect(unfavResult == true)
            let unpinned = try #require(try await store.entry(id: e.id))
            #expect(unpinned.isFavorite == false)
        }
    }
}

@Suite("Search")
struct SearchTests {
    private func seed(_ store: ClipboardStore) async throws {
        _ = try await store.captureText("hello world", sourceApp: nil)
        _ = try await store.captureText("hello swift concurrency", sourceApp: nil)
        _ = try await store.captureText("goodbye cruel world", sourceApp: nil)
        _ = try await store.captureImage(data: makePNG(), format: "png", sourceApp: nil)
    }

    @Test func termSearch() async throws {
        try await withStore { store, _ in
            try await seed(store)
            let hits = try await store.search(SearchQuery(text: "hello"))
            #expect(hits.count == 2)
            #expect(hits.allSatisfy { $0.content?.contains("hello") == true })
        }
    }

    @Test func prefixSearch() async throws {
        try await withStore { store, _ in
            try await seed(store)
            let hits = try await store.search(SearchQuery(text: "concurr"))
            #expect(hits.count == 1)
            #expect(hits[0].content == "hello swift concurrency")
        }
    }

    @Test func multipleTermsAreANDed() async throws {
        try await withStore { store, _ in
            try await seed(store)
            let hits = try await store.search(SearchQuery(text: "hello world"))
            #expect(hits.count == 1)
            #expect(hits[0].content == "hello world")
        }
    }

    @Test func phraseSearch() async throws {
        try await withStore { store, _ in
            try await seed(store)
            let phraseHits = try await store.search(SearchQuery(text: "\"cruel world\""))
            #expect(phraseHits.count == 1)
            #expect(phraseHits[0].content == "goodbye cruel world")
            // Non-adjacent words as a phrase must not match.
            let noHits = try await store.search(SearchQuery(text: "\"goodbye world\""))
            #expect(noHits.isEmpty)
        }
    }

    @Test func typeFilterInQuery() async throws {
        try await withStore { store, _ in
            try await seed(store)
            let textOnly = try await store.search(SearchQuery(type: .text))
            #expect(textOnly.count == 3)
            let imageOnly = try await store.search(SearchQuery(type: .image))
            #expect(imageOnly.count == 1)
        }
    }

    @Test func pinnedOnlySearch() async throws {
        try await withStore { store, _ in
            try await seed(store)
            let all = try await store.search(SearchQuery(text: "hello"))
            _ = try await store.setPinned(true, id: all[0].id)
            let pinned = try await store.search(SearchQuery(text: "hello", pinnedOnly: true))
            #expect(pinned.count == 1)
            #expect(pinned[0].id == all[0].id)
        }
    }

    @Test func favoriteOnlySearch() async throws {
        try await withStore { store, _ in
            try await seed(store)
            let all = try await store.search(SearchQuery(text: "hello"))
            _ = try await store.setFavorite(true, id: all[0].id)
            let favs = try await store.search(SearchQuery(text: "hello", favoriteOnly: true))
            #expect(favs.count == 1)
            #expect(favs[0].id == all[0].id)
        }
    }

    @Test func regexSearch() async throws {
        try await withStore { store, _ in
            try await seed(store)
            let hits = try await store.search(SearchQuery(regex: "^hello .*(world|concurrency)$"))
            #expect(hits.count == 2)
            let anchored = try await store.search(SearchQuery(regex: "^goodbye"))
            #expect(anchored.count == 1)
            #expect(anchored[0].content == "goodbye cruel world")
        }
    }

    @Test func regexSearchIgnoresImages() async throws {
        try await withStore { store, _ in
            try await seed(store)
            let everything = try await store.search(SearchQuery(regex: "."))
            #expect(everything.allSatisfy { $0.type == .text })
            let imageTyped = try await store.search(SearchQuery(regex: ".", type: .image))
            #expect(imageTyped.isEmpty)
        }
    }

    @Test func invalidRegexThrows() async throws {
        try await withStore { store, _ in
            try await seed(store)
            await #expect { try await store.search(SearchQuery(regex: "(unclosed")) } throws: { error in
                guard case ClapCoreError.invalidPattern = error else { return false }
                return true
            }
        }
    }

    @Test func searchLimitAndOffset() async throws {
        try await withStore { store, _ in
            for i in 0..<10 {
                let e = try #require(try await store.captureText("common token \(i)", sourceApp: nil)).entry
                try await store._test_setTimestamps(id: e.id, lastUsedAt: Date(timeIntervalSinceNow: Double(i - 100)))
            }
            let page1 = try await store.search(SearchQuery(text: "common", limit: 3, offset: 0))
            let page2 = try await store.search(SearchQuery(text: "common", limit: 3, offset: 3))
            #expect(page1.map(\.content) == ["common token 9", "common token 8", "common token 7"])
            #expect(page2.map(\.content) == ["common token 6", "common token 5", "common token 4"])

            let regexPage = try await store.search(SearchQuery(regex: "common token \\d", limit: 3, offset: 3))
            #expect(regexPage.map(\.content) == ["common token 6", "common token 5", "common token 4"])
        }
    }
}

@Suite("Delete matching & clear")
struct DeleteTests {
    @Test func deleteMatchingExactText() async throws {
        try await withStore { store, _ in
            _ = try await store.captureText("keep me", sourceApp: nil)
            _ = try await store.captureText("remove me", sourceApp: nil)
            // Input is normalized before the hash lookup.
            let removed = try await store.deleteMatching(text: "  remove me \n")
            #expect(removed == 1)
            let removedAgain = try await store.deleteMatching(text: "remove me")
            #expect(removedAgain == 0)
            let count = try await store.count(type: nil)
            #expect(count == 1)
        }
    }

    @Test func deleteMatchingRegex() async throws {
        try await withStore { store, _ in
            _ = try await store.captureText("token-abc-1", sourceApp: nil)
            _ = try await store.captureText("token-abc-2", sourceApp: nil)
            _ = try await store.captureText("unrelated", sourceApp: nil)
            let removed = try await store.deleteMatching(regexPattern: "^token-abc-\\d$")
            #expect(removed == 2)
            let count = try await store.count(type: nil)
            #expect(count == 1)
        }
    }

    @Test func deleteMatchingInvalidRegexThrows() async throws {
        try await withStore { store, _ in
            await #expect { try await store.deleteMatching(regexPattern: "[bad") } throws: { error in
                guard case ClapCoreError.invalidPattern = error else { return false }
                return true
            }
        }
    }

    @Test func clearAllRemovesRowsAndFilesButKeepsCounters() async throws {
        try await withStore { store, dir in
            _ = try await store.captureText("one", sourceApp: nil)
            _ = try await store.captureText("two", sourceApp: nil)
            let image = try #require(try await store.captureImage(data: makePNG(), format: "png", sourceApp: nil)).entry
            let imageURL = try #require(await store.imageFileURL(for: image))
            _ = try #require(try await store.thumbnailURL(for: image))

            let removed = try await store.clearAll()
            #expect(removed == 3)
            let count = try await store.count(type: nil)
            #expect(count == 0)
            #expect(!FileManager.default.fileExists(atPath: imageURL.path))
            let thumbs = try FileManager.default.contentsOfDirectory(
                at: dir.appendingPathComponent("thumbnails"), includingPropertiesForKeys: nil)
            #expect(thumbs.isEmpty)

            // Counters survive.
            let stats = try await store.stats()
            #expect(stats.eventsToday == 3)

            // FTS is consistent: no ghost hits.
            let ghostHits = try await store.search(SearchQuery(text: "one"))
            #expect(ghostHits.isEmpty)
        }
    }
}

@Suite("Eviction & retention")
struct EvictionTests {
    @Test func countEvictionRemovesOldestNonPinned() async throws {
        try await withStore { store, _ in
            try await store.setConfig("text.max_entries", value: "3")
            for i in 0..<5 {
                let e = try #require(try await store.captureText("entry \(i)", sourceApp: nil)).entry
                try await store._test_setTimestamps(id: e.id, lastUsedAt: Date(timeIntervalSinceNow: Double(i - 100)))
            }
            let evicted = try await store.enforceLimits()
            #expect(evicted == 2)
            let remaining = try await store.list(type: .text, limit: 100, offset: 0)
            #expect(remaining.map(\.content) == ["entry 4", "entry 3", "entry 2"])
        }
    }

    @Test func byteSizeEviction() async throws {
        try await withStore { store, _ in
            let payload = String(repeating: "x", count: 100) // 101 bytes with suffix digit
            for i in 0..<5 {
                let e = try #require(try await store.captureText("\(payload)\(i)", sourceApp: nil)).entry
                try await store._test_setTimestamps(id: e.id, lastUsedAt: Date(timeIntervalSinceNow: Double(i - 100)))
            }
            // 5 entries x 101 bytes = 505 bytes; cap at 250 -> keep 2 newest.
            try await store.setConfig("text.max_size", value: "250")
            let evicted = try await store.enforceLimits()
            #expect(evicted == 3)
            let remaining = try await store.list(type: .text, limit: 100, offset: 0)
            #expect(remaining.count == 2)
            #expect(remaining.map(\.content) == ["\(payload)4", "\(payload)3"])
        }
    }

    @Test func pinnedEntriesAreImmuneToEviction() async throws {
        try await withStore { store, _ in
            try await store.setConfig("text.max_entries", value: "2")
            var oldest: Int64 = 0
            for i in 0..<4 {
                let e = try #require(try await store.captureText("pin test \(i)", sourceApp: nil)).entry
                try await store._test_setTimestamps(id: e.id, lastUsedAt: Date(timeIntervalSinceNow: Double(i - 100)))
                if i == 0 { oldest = e.id }
            }
            _ = try await store.setPinned(true, id: oldest)
            // Pinned rows live outside the budget: 3 non-pinned vs cap 2.
            let evicted = try await store.enforceLimits()
            #expect(evicted == 1)
            let remaining = try await store.list(type: .text, limit: 100, offset: 0)
            #expect(remaining.count == 3)
            #expect(remaining.contains { $0.id == oldest }) // pinned oldest survived
            #expect(remaining.contains { $0.content == "pin test 3" })
            #expect(remaining.contains { $0.content == "pin test 2" })
        }
    }

    @Test func pinnedEntriesDoNotStarveNewCaptures() async throws {
        try await withStore { store, _ in
            try await store.setConfig("text.max_entries", value: "2")
            for i in 0..<3 {
                let e = try #require(try await store.captureText("pinned \(i)", sourceApp: nil)).entry
                _ = try await store.setPinned(true, id: e.id)
            }
            // More pinned rows than the cap; a fresh unpinned capture must
            // survive maintenance, not be silently evicted.
            let fresh = try #require(try await store.captureText("fresh capture", sourceApp: nil)).entry
            let evicted = try await store.enforceLimits()
            #expect(evicted == 0)
            #expect(try await store.entry(id: fresh.id) != nil)
        }
    }

    @Test func oversizeCaptureIsRejected() async throws {
        try await withStore { store, _ in
            try await store.setConfig("text.max_size", value: "100")
            let big = String(repeating: "x", count: 200)
            #expect(try await store.captureText(big, sourceApp: nil) == nil)
            #expect(try await store.count(type: .text) == 0)
            // Small captures still work.
            #expect(try await store.captureText("small", sourceApp: nil) != nil)
        }
    }

    @Test func loweringByteCapEvictsOversizeEntryNotWholeHistory() async throws {
        try await withStore { store, _ in
            for i in 0..<3 {
                let e = try #require(try await store.captureText("keep me \(i)", sourceApp: nil)).entry
                try await store._test_setTimestamps(id: e.id, lastUsedAt: Date(timeIntervalSinceNow: Double(i - 100)))
            }
            let big = try #require(try await store.captureText(String(repeating: "y", count: 500), sourceApp: nil)).entry
            // Cap now smaller than the big (newest) entry alone. The big
            // entry must be evicted first instead of LRU wiping every older
            // entry while chasing an unreachable cap.
            try await store.setConfig("text.max_size", value: "100")
            _ = try await store.enforceLimits()
            let remaining = try await store.list(type: .text, limit: 100, offset: 0)
            #expect(!remaining.contains { $0.id == big.id })
            #expect(remaining.count == 3)
        }
    }

    @Test func imageEvictionDeletesFiles() async throws {
        try await withStore { store, _ in
            try await store.setConfig("image.max_entries", value: "1")
            let img1 = try #require(try await store.captureImage(data: makePNG(red: 0.1), format: "png", sourceApp: nil)).entry
            try await store._test_setTimestamps(id: img1.id, lastUsedAt: Date(timeIntervalSinceNow: -100))
            let img2 = try #require(try await store.captureImage(data: makePNG(red: 0.9), format: "png", sourceApp: nil)).entry
            let url1 = try #require(await store.imageFileURL(for: img1))
            let thumb1 = try #require(try await store.thumbnailURL(for: img1))
            let url2 = try #require(await store.imageFileURL(for: img2))

            let evicted = try await store.enforceLimits()
            #expect(evicted == 1)
            #expect(!FileManager.default.fileExists(atPath: url1.path))
            #expect(!FileManager.default.fileExists(atPath: thumb1.path))
            #expect(FileManager.default.fileExists(atPath: url2.path))
            let count = try await store.count(type: .image)
            #expect(count == 1)
        }
    }

    @Test func retentionDeletesOldNonPinned() async throws {
        try await withStore { store, _ in
            let old = try #require(try await store.captureText("ancient history", sourceApp: nil)).entry
            let oldPinned = try #require(try await store.captureText("ancient but pinned", sourceApp: nil)).entry
            _ = try await store.captureText("fresh", sourceApp: nil)
            let fortyDaysAgo = Date(timeIntervalSinceNow: -40 * 86_400)
            try await store._test_setTimestamps(id: old.id, lastUsedAt: fortyDaysAgo)
            try await store._test_setTimestamps(id: oldPinned.id, lastUsedAt: fortyDaysAgo)
            _ = try await store.setPinned(true, id: oldPinned.id)

            // retention.days = 0 -> never delete.
            let noOp = try await store.applyRetention()
            #expect(noOp == 0)
            let countBefore = try await store.count(type: nil)
            #expect(countBefore == 3)

            try await store.setConfig("retention.days", value: "30")
            let deleted = try await store.applyRetention()
            #expect(deleted == 1)
            let remaining = try await store.list(type: nil, limit: 100, offset: 0)
            #expect(remaining.count == 2)
            #expect(!remaining.contains { $0.id == old.id })
            #expect(remaining.contains { $0.id == oldPinned.id })
        }
    }

    @Test func vacuumIfNeededRuns() async throws {
        try await withStore { store, _ in
            _ = try await store.captureText("some content", sourceApp: nil)
            try await store.vacuumIfNeeded() // must not throw
        }
    }
}

@Suite("Config, stats & doctor")
struct ConfigStatsTests {
    @Test func configDefaultsAndOverrides() async throws {
        try await withStore { store, _ in
            let textMax = try await store.config("text.max_entries")
            #expect(textMax == "100000")
            let imageMax = try await store.config("image.max_size")
            #expect(imageMax == "104857600")
            let missing = try await store.config("nonexistent.key")
            #expect(missing == nil)

            try await store.setConfig("text.max_entries", value: "42")
            let overridden = try await store.config("text.max_entries")
            #expect(overridden == "42")
            try await store.setConfig("custom.key", value: "hello")
            let custom = try await store.config("custom.key")
            #expect(custom == "hello")
        }
    }

    @Test func allConfigMergesDefaults() async throws {
        try await withStore { store, _ in
            try await store.setConfig("retention.days", value: "7")
            let all = try await store.allConfig()
            let dict = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0.value) })
            let expectedKeys = ["text.max_entries", "text.max_size", "image.max_entries",
                                "image.max_size", "monitoring.paused", "exclusions",
                                "retention.days", "launch_at_login", "paste.on_copy",
                                "shell.enabled", "shell.max_entries", "shell.max_size", "shell.histfile"]
            for key in expectedKeys {
                #expect(dict[key] != nil, "missing \(key)")
            }
            #expect(dict["retention.days"] == "7")
            #expect(dict["monitoring.paused"] == "0")
            #expect(dict["exclusions"] == "[]")
            #expect(dict["shell.enabled"] == "1")
        }
    }

    @Test func statsReflectStoreState() async throws {
        try await withStore { store, _ in
            _ = try await store.captureText("stat text", sourceApp: nil)
            _ = try await store.captureText("stat text", sourceApp: nil) // dup
            let img = try #require(try await store.captureImage(data: makePNG(), format: "png", sourceApp: nil)).entry
            _ = try await store.setPinned(true, id: img.id)
            _ = try await store.ingestShell("echo stats", executedAt: nil)

            let stats = try await store.stats()
            #expect(stats.textCount == 1)
            #expect(stats.imageCount == 1)
            #expect(stats.shellCount == 1)
            #expect(stats.textBytes == Int64("stat text".utf8.count))
            #expect(stats.imageBytes == img.sizeBytes)
            #expect(stats.shellBytes == Int64("echo stats".utf8.count))
            #expect(stats.pinnedCount == 1)
            #expect(stats.eventsToday == 3)
            #expect(stats.duplicatesAvoidedToday == 1)
            #expect(stats.oldestEntry != nil)
        }
    }

    @Test func doctorChecksAllPassOnInitializedStore() async throws {
        try await withStore { store, dir in
            _ = try await store.captureText("warm up", sourceApp: nil)
            let checks = ClipboardStore.doctorChecks(dataDir: dir)
            #expect(checks.count == 8)
            for check in checks {
                #expect(check.ok, "doctor check failed: \(check.name) — \(check.detail)")
            }
            let names = checks.map(\.name)
            #expect(names.contains("data directory"))
            #expect(names.contains("database opens"))
            #expect(names.contains("required tables"))
            #expect(names.contains("indexes"))
            #expect(names.contains("FTS5 available"))
            #expect(names.contains("images directory"))
            #expect(names.contains("disk space"))
            #expect(names.contains("shell history"))
        }
    }

    @Test func doctorReportsMissingDataDir() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("clap-doctor-missing-\(UUID().uuidString)")
        let checks = ClipboardStore.doctorChecks(dataDir: bogus)
        let dataDirCheck = checks.first { $0.name == "data directory" }
        #expect(dataDirCheck?.ok == false)
        let dbCheck = checks.first { $0.name == "database opens" }
        #expect(dbCheck?.ok == false)
    }

    @Test func dataDirResolutionPrefersExplicitParam() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clap-explicit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ClipboardStore(dataDir: dir)
        #expect(store.dataDir == dir)
        // Directories were created on init.
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("images").path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("thumbnails").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("clap.sqlite").path))
    }
}

@Suite("Import")
struct ImportTests {
    @Test func importPreservesTimestampsAndMetadata() async throws {
        try await withStore { store, _ in
            let created = Date(timeIntervalSince1970: 1_700_000_000)
            let used = Date(timeIntervalSince1970: 1_750_000_000)
            let result = try #require(try await store.importText(
                "from maccy", createdAt: created, lastUsedAt: used,
                useCount: 7, pinned: true, sourceApp: "com.example.app"))
            #expect(result.merged == false)
            let entry = try #require(try await store.entry(id: result.id))
            #expect(abs(entry.createdAt.timeIntervalSince1970 - created.timeIntervalSince1970) < 0.001)
            #expect(abs(entry.lastUsedAt.timeIntervalSince1970 - used.timeIntervalSince1970) < 0.001)
            #expect(entry.useCount == 7)
            #expect(entry.isPinned)
            #expect(entry.sourceApp == "com.example.app")
        }
    }

    @Test func importMergesWithExistingEntry() async throws {
        try await withStore { store, _ in
            let captured = try #require(try await store.captureText("shared text", sourceApp: nil)).entry
            // Imported copy is older-created but with more uses and a pin.
            let older = Date(timeIntervalSince1970: 1_600_000_000)
            let result = try #require(try await store.importText(
                "  shared text  ", createdAt: older, lastUsedAt: older,
                useCount: 5, pinned: true, sourceApp: nil))
            #expect(result.merged == true)
            #expect(result.id == captured.id)
            #expect(try await store.count(type: .text) == 1)
            let entry = try #require(try await store.entry(id: captured.id))
            #expect(abs(entry.createdAt.timeIntervalSince1970 - older.timeIntervalSince1970) < 0.001)
            // Live capture is more recent than the imported last_used_at.
            #expect(entry.lastUsedAt >= captured.lastUsedAt)
            #expect(entry.useCount == captured.useCount + 5)
            #expect(entry.isPinned)
        }
    }

    @Test func importDoesNotBumpDailyCounters() async throws {
        try await withStore { store, _ in
            _ = try await store.importText("imported quietly",
                                           createdAt: Date(), lastUsedAt: Date(),
                                           useCount: 1, pinned: false, sourceApp: nil)
            let stats = try await store.stats()
            #expect(stats.eventsToday == 0)
        }
    }

    @Test func importImageWritesFileAndMerges() async throws {
        try await withStore { store, _ in
            let png = makePNG(red: 0.4)
            let created = Date(timeIntervalSince1970: 1_700_000_000)
            let first = try #require(try await store.importImage(
                data: png, format: "png", createdAt: created, lastUsedAt: created,
                useCount: 2, pinned: false, sourceApp: nil))
            #expect(first.merged == false)
            let entry = try #require(try await store.entry(id: first.id))
            let url = try #require(await store.imageFileURL(for: entry))
            #expect(FileManager.default.fileExists(atPath: url.path))
            let again = try #require(try await store.importImage(
                data: png, format: "png", createdAt: created, lastUsedAt: created,
                useCount: 1, pinned: false, sourceApp: nil))
            #expect(again.merged == true)
            #expect(try await store.count(type: .image) == 1)
        }
    }
}

@Suite("Shell history store")
struct ShellHistoryStoreTests {
    @Test func ingestShellInsertsNewCommand() async throws {
        try await withStore { store, _ in
            let date = Date(timeIntervalSince1970: 1_720_000_000)
            let result = try #require(try await store.ingestShell("  git status  ", executedAt: date, source: ".zsh_history"))
            #expect(result.merged == false)
            let entry = try #require(try await store.entry(id: result.id))
            #expect(entry.type == .shell)
            #expect(entry.content == "git status")
            #expect(entry.sourceApp == ".zsh_history")
            #expect(entry.useCount == 1)
            #expect(abs(entry.createdAt.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.001)
            #expect(abs(entry.lastUsedAt.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.001)
        }
    }

    @Test func ingestShellDeduplicatesAndBumpsRecency() async throws {
        try await withStore { store, _ in
            let t1 = Date(timeIntervalSince1970: 1_700_000_000)
            let t2 = Date(timeIntervalSince1970: 1_710_000_000)
            let first = try #require(try await store.ingestShell("cargo check", executedAt: t1))
            #expect(first.merged == false)

            let second = try #require(try await store.ingestShell("cargo check", executedAt: t2))
            #expect(second.merged == true)
            #expect(second.id == first.id)

            let entry = try #require(try await store.entry(id: first.id))
            #expect(entry.useCount == 2)
            #expect(abs(entry.createdAt.timeIntervalSince1970 - t1.timeIntervalSince1970) < 0.001)
            #expect(abs(entry.lastUsedAt.timeIntervalSince1970 - t2.timeIntervalSince1970) < 0.001)
            #expect(try await store.count(type: .shell) == 1)
        }
    }

    @Test func shellEvictionRespectsCountLimit() async throws {
        try await withStore { store, _ in
            try await store.setConfig("shell.max_entries", value: "2")
            for i in 0..<4 {
                let d = Date(timeIntervalSinceNow: Double(i - 100))
                _ = try await store.ingestShell("cmd \(i)", executedAt: d)
            }
            let evicted = try await store.enforceLimits()
            #expect(evicted == 2)
            let remaining = try await store.list(type: .shell, limit: 10, offset: 0)
            #expect(remaining.count == 2)
            #expect(remaining.map(\.content) == ["cmd 3", "cmd 2"])
        }
    }

    @Test func shellTabIsolationAndSearch() async throws {
        try await withStore { store, _ in
            _ = try await store.captureText("hello world clipboard", sourceApp: nil)
            _ = try await store.ingestShell("hello world terminal command", executedAt: nil)

            // Classic tab filter (text + image) does not return shell commands:
            let classic = try await store.search(SearchQuery(types: [.text, .image], limit: 10, offset: 0))
            #expect(classic.count == 1)
            #expect(classic[0].type == .text)

            // Shell tab filter only returns shell commands:
            let shellOnly = try await store.list(type: .shell, limit: 10, offset: 0)
            #expect(shellOnly.count == 1)
            #expect(shellOnly[0].type == .shell)

            // FTS search with query syntax type:shell
            let parsed = SearchQuery.parse("hello type:shell", limit: 10, offset: 0)
            #expect(parsed.type == .shell)
            let ftsHits = try await store.search(parsed)
            #expect(ftsHits.count == 1)
            #expect(ftsHits[0].content == "hello world terminal command")

            // Regex search over shell commands:
            let regexHits = try await store.search(SearchQuery(regex: "terminal command", type: .shell))
            #expect(regexHits.count == 1)
            #expect(regexHits[0].content == "hello world terminal command")
        }
    }
}
