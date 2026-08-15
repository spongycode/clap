import Foundation
import ClapCore

/// Hidden command: `clap _capture <text>`. Seeds the store the same way the
/// app's pasteboard monitor would. Undocumented (not in help); used for
/// testing and scripting.
enum CaptureCommand {
    static let usage = "Usage: clap _capture <text>"

    static func run(_ args: [String], context: CLIContext) async {
        let parsed = ArgParser.parse(args, usage: usage)
        let text = parsed.positionals.joined(separator: " ")
        guard !text.isEmpty else {
            CLI.usageError("_capture requires text", usage: usage)
        }

        let result = await CLI.run {
            let store = try context.makeStore()
            return try await store.captureText(text, sourceApp: nil)
        }
        guard let result else {
            CLI.fail("nothing to capture (empty after normalization)")
        }
        Notify.storeChanged()
        print("captured id=\(result.entry.id) duplicate=\(result.wasDuplicate)")
    }
}
