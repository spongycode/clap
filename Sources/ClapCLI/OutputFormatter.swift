import Foundation
import ClapCore

/// Plain-text tables, previews, timestamps and stable JSON output.
enum OutputFormatter {
    static let previewMax = 60

    // MARK: - Previews

    /// Single-line preview truncated to 60 characters, control chars stripped.
    /// Images render as "[image <format>, <size>]".
    static func preview(_ entry: ClipboardEntry) -> String {
        switch entry.type {
        case .text, .shell:
            return previewText(entry.content ?? "")
        case .image:
            let format = entry.imageFormat ?? "?"
            return "[image \(format), \(ByteSize.format(entry.sizeBytes))]"
        }
    }

    static func previewText(_ content: String) -> String {
        var flat = ""
        flat.reserveCapacity(min(content.count, previewMax + 1))
        for character in content {
            if flat.count > previewMax { break }
            if character == "\n" || character == "\r" || character == "\t" {
                flat.append(" ")
            } else if character.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) {
                continue
            } else {
                flat.append(character)
            }
        }
        if flat.count > previewMax {
            return String(flat.prefix(previewMax - 1)) + "…"
        }
        return flat
    }

    // MARK: - Time

    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        case ..<(86_400 * 30): return "\(seconds / 86_400)d ago"
        default: return dayFormatter.string(from: date)
        }
    }

    static let dayFormatter = makeFormatter("yyyy-MM-dd")
    static let minuteFormatter = makeFormatter("yyyy-MM-dd HH:mm")
    static let secondFormatter = makeFormatter("yyyy-MM-dd HH:mm:ss")
    static let iso8601 = ISO8601DateFormatter()

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    // MARK: - Table

    /// Aligned plain-text table: ID, pin marker, type, preview, recency.
    static func table(_ entries: [ClipboardEntry]) -> String {
        var rows: [[String]] = [["ID", "P", "TYPE", "PREVIEW", "LAST USED"]]
        for entry in entries {
            rows.append([
                String(entry.id),
                entry.isPinned ? "*" : "",
                entry.type.rawValue,
                preview(entry),
                relativeTime(entry.lastUsedAt),
            ])
        }
        let columns = rows[0].count
        var widths = [Int](repeating: 0, count: columns)
        for row in rows {
            for (i, cell) in row.enumerated() {
                widths[i] = max(widths[i], cell.count)
            }
        }
        return rows.map { row in
            row.enumerated().map { i, cell in
                let padding = String(repeating: " ", count: widths[i] - cell.count)
                // Right-align the ID column, left-align the rest; no trailing
                // padding on the last column.
                if i == 0 { return padding + cell }
                if i == columns - 1 { return cell }
                return cell + padding
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    // MARK: - JSON

    struct EntryJSON: Codable {
        let id: Int64
        let type: String
        let content: String?
        let imagePath: String?
        let contentHash: String
        let createdAt: String
        let lastUsedAt: String
        let sizeBytes: Int64
        let isPinned: Bool
        let useCount: Int
        let sourceApp: String?
    }

    static func entryJSON(_ entry: ClipboardEntry, dataDir: URL) -> EntryJSON {
        let imagePath = entry.imagePath.map {
            dataDir.appendingPathComponent("images", isDirectory: true)
                .appendingPathComponent($0).path
        }
        return EntryJSON(
            id: entry.id,
            type: entry.type.rawValue,
            content: (entry.type == .text || entry.type == .shell) ? entry.content : nil,
            imagePath: imagePath,
            contentHash: entry.contentHash,
            createdAt: iso8601.string(from: entry.createdAt),
            lastUsedAt: iso8601.string(from: entry.lastUsedAt),
            sizeBytes: entry.sizeBytes,
            isPinned: entry.isPinned,
            useCount: entry.useCount,
            sourceApp: entry.sourceApp
        )
    }

    /// Pretty-printed JSON with stable (sorted) key order.
    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func printEntriesJSON(_ entries: [ClipboardEntry], dataDir: URL) {
        print(encodeJSON(entries.map { entryJSON($0, dataDir: dataDir) }))
    }
}
