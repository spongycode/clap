import Foundation
import ClapCore

enum SearchCommand {
    static let usage = """
    Usage: clap search <query> [--regex <pat>] [--type text|image|shell] [--limit N] [--offset N] [--json]

    Full-text search over clipboard and shell history. Query syntax: bare terms
    (prefix-matched, AND-combined), "quoted phrase", regex:<pat>,
    type:text|image|shell.
      --regex <pat>             Regex search (overrides the query)
      --type text|image|shell   Restrict entry type
      --limit N                 Max rows (default 20)
      --offset N                Skip N rows
      --json                    JSON output
    """

    static func run(_ args: [String], context: CLIContext) async {
        let parsed = ArgParser.parse(args,
                                     boolFlags: ["--json"],
                                     valueFlags: ["--regex", "--type", "--limit", "--offset"],
                                     usage: usage)
        let limit = parsed.int("--limit", default: 20, min: 1)
        let offset = parsed.int("--offset", default: 0, min: 0)

        var typeFilter: EntryType?
        if let raw = parsed.value("--type") {
            guard let type = EntryType(rawValue: raw.lowercased()) else {
                CLI.usageError("invalid --type '\(raw)' (expected text, image or shell)", usage: usage)
            }
            typeFilter = type
        }

        let rawQuery = parsed.positionals.joined(separator: " ")
        var query: SearchQuery
        if let pattern = parsed.value("--regex") {
            query = SearchQuery(regex: pattern, type: typeFilter, limit: limit, offset: offset)
        } else if !rawQuery.isEmpty {
            query = SearchQuery.parse(rawQuery, limit: limit, offset: offset)
            if let typeFilter { query.type = typeFilter }  // CLI flag wins
        } else {
            CLI.usageError("search requires a query or --regex", usage: usage)
        }

        let (entries, dataDir) = await CLI.run { () -> ([ClipboardEntry], URL) in
            let store = try context.makeStore()
            let entries = try await store.search(query)
            return (entries, store.dataDir)
        }

        if parsed.has("--json") {
            OutputFormatter.printEntriesJSON(entries, dataDir: dataDir)
        } else if entries.isEmpty {
            print("No matches.")
        } else {
            print(OutputFormatter.table(entries))
        }
        exit(entries.isEmpty ? ExitCode.failure : ExitCode.ok)
    }
}
