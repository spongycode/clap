import Foundation
import ClapCore

enum GetCommand {
    static let usage = """
    Usage: clap get <id> [--json]

    Prints one entry in full. On a terminal: metadata header then the raw
    content (or the image file path). When stdout is piped: only the raw
    content / image path, for scripting.
    """

    static func run(_ args: [String], context: CLIContext) async {
        let parsed = ArgParser.parse(args, boolFlags: ["--json"], usage: usage)
        let id = parsed.requiredID(commandName: "get")

        let (entry, dataDir) = await CLI.run { () -> (ClipboardEntry?, URL) in
            let store = try context.makeStore()
            return (try await store.entry(id: id), store.dataDir)
        }
        guard let entry else {
            CLI.fail("entry \(id) not found")
        }

        if parsed.has("--json") {
            do {
                print(try OutputFormatter.encodeJSON(OutputFormatter.entryJSON(entry, dataDir: dataDir)))
            } catch {
                CLI.fail("JSON encoding failed: \(error.localizedDescription)")
            }
            return
        }

        let imageAbsolutePath: String? = entry.type == .image
            ? entry.imagePath.map {
                dataDir.appendingPathComponent("images", isDirectory: true)
                    .appendingPathComponent($0).path
            }
            : nil

        // Pipe-friendly: raw content only when stdout is not a TTY.
        guard CLI.stdoutIsTTY else {
            switch entry.type {
            case .text, .shell:
                print(entry.content ?? "")
            case .image:
                print(imageAbsolutePath ?? "")
            }
            return
        }

        let rows: [(String, String)] = [
            ("ID", String(entry.id)),
            ("Type", entry.type.rawValue),
            ("Pinned", entry.isPinned ? "yes" : "no"),
            ("Created", OutputFormatter.secondFormatter.string(from: entry.createdAt)),
            ("Last used", OutputFormatter.secondFormatter.string(from: entry.lastUsedAt)),
            ("Use count", String(entry.useCount)),
            ("Size", ByteSize.format(entry.sizeBytes)),
            ("Hash", entry.contentHash),
            ("Source app", entry.sourceApp ?? "—")
        ] + (entry.type == .image
                ? [("Format", entry.imageFormat ?? "?"), ("File", imageAbsolutePath ?? "—")]
                : [])

        let labelWidth = rows.map { $0.0.count }.max() ?? 0
        for (label, value) in rows {
            let padding = String(repeating: " ", count: labelWidth - label.count)
            print("\(label):\(padding)  \(value)")
        }
        if entry.type == .text || entry.type == .shell {
            print(String(repeating: "-", count: 40))
            print(entry.content ?? "")
        }
    }
}
