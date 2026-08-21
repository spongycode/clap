import Foundation
import ClapCore

enum StatsCommand {
    static let usage = """
    Usage: clap stats [--json]

    Prints storage and activity statistics.
    """

    struct StatsJSON: Codable {
        let textCount: Int
        let imageCount: Int
        let shellCount: Int
        let textBytes: Int64
        let imageBytes: Int64
        let shellBytes: Int64
        let totalBytes: Int64
        let pinnedCount: Int
        let eventsToday: Int
        let duplicatesAvoidedToday: Int
        let oldestEntry: String?
    }

    static func run(_ args: [String], context: CLIContext) async {
        let parsed = ArgParser.parse(args, boolFlags: ["--json"], usage: usage)
        guard parsed.positionals.isEmpty else {
            CLI.usageError("unexpected argument '\(parsed.positionals[0])'", usage: usage)
        }

        let stats = await CLI.run {
            let store = try context.makeStore()
            return try await store.stats()
        }

        let totalBytes = stats.textBytes + stats.imageBytes + stats.shellBytes

        if parsed.has("--json") {
            let json = StatsJSON(
                textCount: stats.textCount,
                imageCount: stats.imageCount,
                shellCount: stats.shellCount,
                textBytes: stats.textBytes,
                imageBytes: stats.imageBytes,
                shellBytes: stats.shellBytes,
                totalBytes: totalBytes,
                pinnedCount: stats.pinnedCount,
                eventsToday: stats.eventsToday,
                duplicatesAvoidedToday: stats.duplicatesAvoidedToday,
                oldestEntry: stats.oldestEntry.map { OutputFormatter.iso8601.string(from: $0) }
            )
            do {
                print(try OutputFormatter.encodeJSON(json))
            } catch {
                CLI.fail("JSON encoding failed: \(error.localizedDescription)")
            }
            return
        }

        let oldest = stats.oldestEntry.map {
            OutputFormatter.minuteFormatter.string(from: $0)
        } ?? "—"
        let rows: [(String, String)] = [
            ("Text entries", String(stats.textCount)),
            ("Image entries", String(stats.imageCount)),
            ("Shell entries", String(stats.shellCount)),
            ("Text storage", ByteSize.format(stats.textBytes)),
            ("Image storage", ByteSize.format(stats.imageBytes)),
            ("Shell storage", ByteSize.format(stats.shellBytes)),
            ("Total storage", ByteSize.format(totalBytes)),
            ("Clipboard events today", String(stats.eventsToday)),
            ("Duplicates avoided", String(stats.duplicatesAvoidedToday)),
            ("Oldest entry", oldest)
        ]
        let labelWidth = rows.map { $0.0.count }.max() ?? 0
        print("Clap Statistics")
        for (label, value) in rows {
            let padding = String(repeating: " ", count: labelWidth - label.count)
            print("  \(label):\(padding)  \(value)")
        }
    }
}
