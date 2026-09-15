import Testing
import Foundation
@testable import ClapCore

@Suite("Backup export & restore")
struct BackupTests {

    @Test func exportThenImportRoundTripsEverything() async throws {
        let png = makePNG()
        try await withStore { source, _ in
            // Seed a rich history: text, image, shell, pinned, favorite,
            // tagged, shortcut, multiple sources.
            let text = try #require(try await source.captureText(
                "backup me", sourceApp: "com.apple.Notes")).entry
            _ = try await source.setPinned(true, id: text.id)
            _ = try await source.addTag("work", entryID: text.id)

            let image = try #require(try await source.captureImage(
                data: png, format: "png", sourceApp: nil)).entry
            _ = try await source.setFavorite(true, id: image.id)
            _ = try await source.addTag("shots", entryID: image.id)

            _ = try await source.ingestShell("docker compose up", executedAt: nil)

            // Export.
            let backupDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("clap-backup-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: backupDir) }
            let exported = try await source.exportBackup(to: backupDir)
            #expect(exported == 3)
            #expect(FileManager.default.fileExists(
                atPath: backupDir.appendingPathComponent("backup.json").path))
            #expect(FileManager.default.fileExists(
                atPath: backupDir.appendingPathComponent("images").path))

            // Restore into a FRESH store.
            try await withStore { target, _ in
                let result = try await target.importBackup(from: backupDir)
                #expect(result.imported == 3)
                #expect(result.merged == 0)
                #expect(result.skipped == 0)

                // Text entry: content, pin, tag survive.
                let restoredText = try #require(
                    try await target.search(SearchQuery(text: "backup me", limit: 1, offset: 0)).first)
                #expect(restoredText.isPinned)
                #expect(restoredText.tags == ["work"])
                #expect(restoredText.sourceApp == "com.apple.Notes")

                // Image entry: bytes are identical, favorite + tag survive,
                // thumbnail regenerates.
                let restoredImage = try #require(
                    try await target.list(type: .image, limit: 1, offset: 0).first)
                #expect(restoredImage.isFavorite)
                #expect(restoredImage.tags == ["shots"])
                #expect(restoredImage.contentHash == image.contentHash)
                let restoredPNG = try #require(await target.imageFileURL(for: restoredImage))
                #expect(try Data(contentsOf: restoredPNG) == png)
                #expect(try await target.thumbnailURL(for: restoredImage) != nil)

                // Shell entry survives with its type.
                let shell = try await target.list(type: .shell, limit: 10, offset: 0)
                #expect(shell.contains { $0.content == "docker compose up" })
            }
        }
    }

    @Test func importIsIdempotentViaMerge() async throws {
        try await withStore { source, _ in
            _ = try await source.captureText("dedupe me", sourceApp: nil)
            let backupDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("clap-backup-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: backupDir) }
            _ = try await source.exportBackup(to: backupDir)

            try await withStore { target, _ in
                _ = try await target.importBackup(from: backupDir)
                // Second import must MERGE, not duplicate.
                let second = try await target.importBackup(from: backupDir)
                #expect(second.imported == 0)
                #expect(second.merged == 1)
                let all = try await target.list(type: .text, limit: 10, offset: 0)
                #expect(all.count == 1)
            }
        }
    }

    @Test func importRejectsForeignFilesAndSkipsMissingImages() async throws {
        try await withStore { target, _ in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("clap-backup-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            try #"{"format": "something-else", "entries": []}"#.write(
                to: dir.appendingPathComponent("backup.json"),
                atomically: true, encoding: .utf8)
            await #expect(throws: ClapCoreError.self) {
                try await target.importBackup(from: dir)
            }

            // Entry referencing a missing image file is skipped, not fatal.
            let payload = """
            {"format":"clap-backup","version":1,"exportedAt":"2026-01-01T00:00:00Z",
             "entries":[{"type":"image","content":null,"imagePath":"ghost.png",
                         "imageFormat":"png","createdAt":"2026-01-01T00:00:00Z",
                         "lastUsedAt":"2026-01-01T00:00:00Z","sizeBytes":10,
                         "isPinned":false,"isFavorite":false,"useCount":1,
                         "sourceApp":null,"shortcut":null,"tags":[]}]}
            """
            try payload.write(to: dir.appendingPathComponent("backup.json"),
                              atomically: true, encoding: .utf8)
            let result = try await target.importBackup(from: dir)
            #expect(result.skipped == 1)
            #expect(result.imported == 0)
        }
    }
}
