import Foundation
import ClapCore

/// `clap pause` / `clap resume` — toggles monitoring.paused and tells the app.
enum PauseCommand {
    static func usage(paused: Bool) -> String {
        let verb = paused ? "pause" : "resume"
        return """
        Usage: clap \(verb)

        \(paused ? "Pauses clipboard monitoring." : "Resumes clipboard monitoring.")
        """
    }

    static func run(_ args: [String], paused: Bool, context: CLIContext) async {
        let parsed = ArgParser.parse(args, usage: usage(paused: paused))
        guard parsed.positionals.isEmpty else {
            CLI.usageError("unexpected argument '\(parsed.positionals[0])'",
                           usage: usage(paused: paused))
        }

        await CLI.run {
            let store = try context.makeStore()
            try await store.setConfig("monitoring.paused", value: paused ? "1" : "0")
        }
        Notify.configChanged()
        print(paused ? "Clipboard monitoring paused." : "Clipboard monitoring resumed.")
    }
}
