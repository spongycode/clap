import Foundation
import Darwin
import ClapCore

/// `clap add <text>` — insert a clipboard history entry directly.
/// Counterpart of `clap out` (delete). Also accepts piped input:
/// `echo hi | clap add -`. The hidden `_capture` spelling is kept as an
/// alias for existing scripts.
enum AddCommand {
    static let usage = """
    Usage: clap add <text> [-]
           echo <text> | clap add -
           clap in <text>                        (alias of add)

    Inserts an entry into clipboard history exactly as if it had been copied.
    Deduplicates like normal capture: re-adding known text bumps its recency.

    Options:
      -               Read the text from standard input instead of arguments
    """

    /// `legacyOutput` preserves the hidden `_capture` script-facing format.
    static func run(_ args: [String], context: CLIContext, legacyOutput: Bool = false) async {
        let parsed = ArgParser.parse(args,
                                     boolFlags: ["-"],
                                     usage: usage)

        var text = parsed.positionals.joined(separator: " ")
        if parsed.has("-") && CLI.stdinIsTTY {
            CLI.usageError("add - reads standard input, but stdin is a terminal; pipe text instead",
                           usage: usage)
        }
        if parsed.has("-") || (!CLI.stdinIsTTY && text.isEmpty) {
            guard !CLI.stdinIsTTY else {
                CLI.usageError("add requires text arguments or piped input (-)", usage: usage)
            }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let decoded = String(data: data, encoding: .utf8),
                  !decoded.isEmpty else {
                CLI.usageError("add: standard input contained no valid UTF-8 text",
                               usage: usage)
            }
            text = decoded
        }
        guard !text.isEmpty else {
            CLI.usageError("add requires text", usage: usage)
        }

        let result = await CLI.run {
            let store = try context.makeStore()
            return try await store.captureText(text, sourceApp: nil)
        }
        guard let result else {
            CLI.fail("nothing to capture (empty after normalization)")
        }
        Notify.storeChanged()

        if legacyOutput {
            print("captured id=\(result.entry.id) duplicate=\(result.wasDuplicate)")
        } else if result.wasDuplicate {
            print("Entry \(result.entry.id) already exists — bumped to top.")
        } else {
            print("Added entry \(result.entry.id).")
        }
    }
}
