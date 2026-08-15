import Foundation
import Testing
@testable import ClapCore

@Suite("Image capture & thumbnails")
struct ImageTests {
    @Test func captureImageWritesFileAndRow() async throws {
        try await withStore { store, dir in
            let png = makePNG(width: 12, height: 6)
            let result = try #require(try await store.captureImage(data: png, format: "PNG", sourceApp: "com.test.app"))
            let entry = result.entry
            #expect(result.wasDuplicate == false)
            #expect(entry.type == .image)
            #expect(entry.content == nil)
            #expect(entry.imageFormat == "png")
            #expect(entry.sizeBytes == Int64(png.count))
            #expect(entry.contentHash == ContentHasher.imageHash(png))
            #expect(entry.imagePath == "\(entry.contentHash).png")

            let fileURL = try #require(await store.imageFileURL(for: entry))
            #expect(fileURL.path.hasSuffix("images/\(entry.contentHash).png"))
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
            // Original bytes stored verbatim.
            let stored = try Data(contentsOf: fileURL)
            #expect(stored == png)
        }
    }

    @Test func emptyImageDataReturnsNil() async throws {
        try await withStore { store, _ in
            let result = try await store.captureImage(data: Data(), format: "png", sourceApp: nil)
            #expect(result == nil)
            let count = try await store.count(type: .image)
            #expect(count == 0)
        }
    }

    @Test func duplicateImageTouchesWithoutRewritingFile() async throws {
        try await withStore { store, _ in
            let png = makePNG()
            let first = try #require(try await store.captureImage(data: png, format: "png", sourceApp: nil))
            let fileURL = try #require(await store.imageFileURL(for: first.entry))
            let originalModDate = try FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

            try await store._test_setTimestamps(id: first.entry.id,
                                                lastUsedAt: Date(timeIntervalSinceNow: -100))
            let second = try #require(try await store.captureImage(data: png, format: "png", sourceApp: nil))
            #expect(second.wasDuplicate == true)
            #expect(second.entry.id == first.entry.id)
            #expect(second.entry.useCount == 2)
            let count = try await store.count(type: .image)
            #expect(count == 1)

            let newModDate = try FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
            #expect(newModDate == originalModDate) // file untouched
        }
    }

    @Test func thumbnailGeneratedLazilyWithMax400LongEdge() async throws {
        try await withStore { store, dir in
            // 600x200 source: thumbnail long edge must shrink to <= 400.
            let png = makePNG(width: 600, height: 200)
            let entry = try #require(try await store.captureImage(data: png, format: "png", sourceApp: nil)).entry

            let thumbsDir = dir.appendingPathComponent("thumbnails")
            let before = try FileManager.default.contentsOfDirectory(atPath: thumbsDir.path)
            #expect(before.isEmpty)

            let thumbURL = try #require(try await store.thumbnailURL(for: entry))
            #expect(thumbURL.lastPathComponent == "\(entry.contentHash).png")
            #expect(FileManager.default.fileExists(atPath: thumbURL.path))
            let size = try #require(imagePixelSize(at: thumbURL))
            #expect(max(size.width, size.height) <= 400)
            #expect(size.width > size.height) // aspect preserved

            // Second call reuses the existing file.
            let again = try #require(try await store.thumbnailURL(for: entry))
            #expect(again == thumbURL)
        }
    }

    @Test func smallImageThumbnailDoesNotThrow() async throws {
        try await withStore { store, _ in
            let entry = try #require(try await store.captureImage(data: makePNG(width: 8, height: 8),
                                                                  format: "png", sourceApp: nil)).entry
            let thumbURL = try #require(try await store.thumbnailURL(for: entry))
            #expect(FileManager.default.fileExists(atPath: thumbURL.path))
        }
    }

    @Test func imageHelpersReturnNilForTextEntries() async throws {
        try await withStore { store, _ in
            let text = try #require(try await store.captureText("not an image", sourceApp: nil)).entry
            let fileURL = await store.imageFileURL(for: text)
            #expect(fileURL == nil)
            let thumbURL = try await store.thumbnailURL(for: text)
            #expect(thumbURL == nil)
        }
    }

    @Test func deletingImageEntryRemovesFiles() async throws {
        try await withStore { store, _ in
            let entry = try #require(try await store.captureImage(data: makePNG(), format: "png", sourceApp: nil)).entry
            let fileURL = try #require(await store.imageFileURL(for: entry))
            let thumbURL = try #require(try await store.thumbnailURL(for: entry))
            let deleted = try await store.delete(id: entry.id)
            #expect(deleted == true)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
            #expect(!FileManager.default.fileExists(atPath: thumbURL.path))
        }
    }
}
