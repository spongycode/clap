import Foundation
import ClapCore

enum ListCommand {
    static let usage = """
    Usage: clap list [--images] [--shell] [--limit N] [--offset N] [--json]

    Lists clipboard and shell entries, most recently used first.
      --images    Only image entries
      --shell     Only shell command entries
      --limit N   Max rows (default 20)
      --offset N  Skip N rows
      --json      JSON output
    """

    static func run(_ args: [String], context: CLIContext) async {
        let parsed = ArgParser.parse(args,
                                     boolFlags: ["--images", "--shell", "--json"],
                                     valueFlags: ["--limit", "--offset"],
                                     usage: usage)
        guard parsed.positionals.isEmpty else {
            CLI.usageError("unexpected argument '\(parsed.positionals[0])'", usage: usage)
        }
        if parsed.has("--images") && parsed.has("--shell") {
            CLI.usageError("--images and --shell are mutually exclusive", usage: usage)
        }
        let limit = parsed.int("--limit", default: 20, min: 1)
        let offset = parsed.int("--offset", default: 0, min: 0)
        let type: EntryType? = parsed.has("--images") ? .image : (parsed.has("--shell") ? .shell : nil)

        let (entries, dataDir) = await CLI.run { () -> ([ClipboardEntry], URL) in
            let store = try context.makeStore()
            let entries = try await store.list(type: type, limit: limit, offset: offset)
            return (entries, store.dataDir)
        }

        if parsed.has("--json") {
            OutputFormatter.printEntriesJSON(entries, dataDir: dataDir)
            return
        }
        guard !entries.isEmpty else {
            print("No entries.")
            return
        }
        print(OutputFormatter.table(entries))
    }
}
