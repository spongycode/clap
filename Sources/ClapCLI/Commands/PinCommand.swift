import Foundation
import ClapCore

enum PinCommand {
    static func usage(pinned: Bool) -> String {
        let verb = pinned ? "pin" : "unpin"
        return """
        Usage: clap \(verb) <id>

        \(pinned ? "Pins an entry so it is never evicted." : "Removes the pin from an entry.")
        """
    }

    static func run(_ args: [String], pinned: Bool, context: CLIContext) async {
        let parsed = ArgParser.parse(args, usage: usage(pinned: pinned))
        let id = parsed.requiredID(commandName: pinned ? "pin" : "unpin")

        let changed = await CLI.run {
            let store = try context.makeStore()
            return try await store.setPinned(pinned, id: id)
        }
        guard changed else {
            CLI.fail("entry \(id) not found")
        }
        Notify.storeChanged()
        print("\(pinned ? "Pinned" : "Unpinned") entry \(id).")
    }
}
