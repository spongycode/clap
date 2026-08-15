import Foundation
import ClapCore

enum ClearCommand {
    static let usage = """
    Usage: clap clear [--force]

    Deletes every clipboard entry (and stored image files).
      --force   Skip the confirmation prompt
    """

    static func run(_ args: [String], context: CLIContext) async {
        let parsed = ArgParser.parse(args, boolFlags: ["--force"], usage: usage)
        guard parsed.positionals.isEmpty else {
            CLI.usageError("unexpected argument '\(parsed.positionals[0])'", usage: usage)
        }

        let removed = await CLI.run { () -> Int in
            let store = try context.makeStore()
            if !parsed.has("--force") {
                let total = try await store.count(type: nil)
                print("Delete all \(total) clipboard entries? [y/N] ", terminator: "")
                let answer = readLine()?
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased() ?? ""
                guard ["y", "yes"].contains(answer) else {
                    print("Aborted.")
                    exit(ExitCode.ok)
                }
            }
            return try await store.clearAll()
        }
        Notify.storeChanged()
        print("Removed \(removed) \(removed == 1 ? "entry" : "entries").")
    }
}
