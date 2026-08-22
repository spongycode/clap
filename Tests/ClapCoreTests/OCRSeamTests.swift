import Testing
import os
import Foundation
@testable import ClapCore

/// Deterministic OCR stub: no Vision, no latency, fully predictable.
struct MockOCREngine: OCREngine {
    let result: String?

    func recognizeText(from imageData: Data) async -> String? {
        result
    }
}

@Suite("OCR seam & injected clock")
struct OCRSeamTests {

    @Test func captureImageStoresMockedOCRTextAndSearchFindsIt() async throws {
        let png = makePNG()
        try await withStore { store, _ in
            let seeded = try ClipboardStore(dataDir: store.dataDir,
                                            now: { Date() },
                                            ocr: MockOCREngine(result: "hello receipt"))
            _ = try await seeded.captureImage(data: png, format: "png", sourceApp: nil)

            let entry = try await seeded.list(type: .image, limit: 1, offset: 0).first
            #expect(entry != nil)
            #expect(entry?.content == "hello receipt")

            let hits = try await seeded.search(SearchQuery(text: "receipt", limit: 10, offset: 0))
            #expect(hits.count == 1)
        }
    }

    @Test func captureImageWithoutOCRTextStoresNilContent() async throws {
        let png = makePNG()
        try await withStore { store, _ in
            let seeded = try ClipboardStore(dataDir: store.dataDir,
                                            ocr: MockOCREngine(result: nil))
            _ = try await seeded.captureImage(data: png, format: "png", sourceApp: nil)
            let entry = try await seeded.list(type: .image, limit: 1, offset: 0).first
            #expect(entry?.content == nil)
        }
    }

    @Test func injectedClockDrivesTimestamps() async throws {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        try await withStore { store, _ in
            let seeded = try ClipboardStore(dataDir: store.dataDir, now: { fixed })
            let (entry, _) = try await seeded.captureText("clock test", sourceApp: nil)!
            #expect(entry.createdAt == fixed)
            #expect(entry.lastUsedAt == fixed)
        }
    }

    @Test func recencyOrderingUsesInjectedClockProgression() async throws {
        let clockState = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_700_000_000))
        try await withStore { store, _ in
            let seeded = try ClipboardStore(dataDir: store.dataDir,
                                            now: { clockState.withLock { $0 } })
            _ = try await seeded.captureText("older", sourceApp: nil)!
            clockState.withLock { $0 = $0.addingTimeInterval(60) }
            _ = try await seeded.captureText("newer", sourceApp: nil)
            let list = try await seeded.list(type: .text, limit: 10, offset: 0)
            #expect(list.first?.content == "newer")
        }
    }
}
