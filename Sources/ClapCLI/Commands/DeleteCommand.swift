import Foundation
import ClapCore

enum DeleteCommand {
    static let usage = """
    Usage: clap delete <id>
           clap delete --text <exact text>
           clap delete --regex <pattern>

    Deletes entries by id, by exact (normalized) text, or by regex over text
    content. Exits 1 when nothing matched.
    """

    static let outUsage = "Usage: clap out <id | exact text>  (alias for clap delete)"

    static func run(_ args: [String], context: CLIContext) async {
        let parsed = ArgParser.parse(args,
                                     valueFlags: ["--text", "--regex"],
                                     usage: usage)
        let text = parsed.value("--text")
        let regex = parsed.value("--regex")
        let selectors = [text != nil, regex != nil, !parsed.positionals.isEmpty]
            .filter { $0 }.count
        guard selectors == 1 else {
            CLI.usageError("delete needs exactly one of: <id>, --text, --regex", usage: usage)
        }

        if let text {
            await deleteByText(text, context: context)
        } else if let regex {
            await deleteByRegex(regex, context: context)
        } else {
            let id = parsed.requiredID(commandName: "delete")
            await deleteByID(id, context: context)
        }
    }

    /// `clap out [<id> | <exact text>]` — alias for delete. All-digits single
    /// argument is treated as an id, anything else as exact text.
    static func runOutAlias(_ args: [String], context: CLIContext) async {
        if args.contains("--help") || args.contains("-h") {
            print(outUsage)
            return
        }
        let parsed = ArgParser.parse(args, usage: outUsage)
        guard !parsed.positionals.isEmpty else {
            CLI.printError(outUsage)
            exit(ExitCode.usage)
        }
        let joined = parsed.positionals.joined(separator: " ")
        if parsed.positionals.count == 1,
           !joined.isEmpty,
           joined.allSatisfy(\.isNumber),
           let id = Int64(joined) {
            await deleteByID(id, context: context)
        } else {
            await deleteByText(joined, context: context)
        }
    }

    // MARK: - Shared deletion paths

    static func deleteByID(_ id: Int64, context: CLIContext) async {
        let deleted = await CLI.run {
            let store = try context.makeStore()
            return try await store.delete(id: id)
        }
        guard deleted else {
            CLI.fail("entry \(id) not found")
        }
        Notify.storeChanged()
        print("Deleted 1 entry.")
    }

    static func deleteByText(_ text: String, context: CLIContext) async {
        let count = await CLI.run {
            let store = try context.makeStore()
            return try await store.deleteMatching(text: text)
        }
        report(count: count)
    }

    static func deleteByRegex(_ pattern: String, context: CLIContext) async {
        let count = await CLI.run {
            let store = try context.makeStore()
            return try await store.deleteMatching(regexPattern: pattern)
        }
        report(count: count)
    }

    private static func report(count: Int) {
        guard count > 0 else {
            print("Deleted 0 entries.")
            exit(ExitCode.failure)
        }
        Notify.storeChanged()
        print("Deleted \(count) \(count == 1 ? "entry" : "entries").")
    }
}
