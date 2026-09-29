import Foundation
import ClapCore

/// `clap pin/unpin <id>` and `clap fav/unfav <id>` — both flags are
/// eviction-exempt markers with identical CLI shape.
enum PinCommand {
    enum Flag {
        case pin, favorite

        func verb(_ on: Bool) -> String {
            switch self {
            case .pin: return on ? "pin" : "unpin"
            case .favorite: return on ? "fav" : "unfav"
            }
        }

        func pastTense(_ on: Bool) -> String {
            switch self {
            case .pin: return on ? "Pinned" : "Unpinned"
            case .favorite: return on ? "Favorited" : "Unfavorited"
            }
        }

        func summary(_ on: Bool) -> String {
            switch self {
            case .pin:
                return on ? "Pins an entry so it is never evicted." : "Removes the pin from an entry."
            case .favorite:
                return on ? "Marks an entry as a favorite (shown in the Favs tab, never evicted)."
                          : "Removes an entry from favorites."
            }
        }
    }

    static func usage(_ flag: Flag, on: Bool) -> String {
        """
        Usage: clap \(flag.verb(on)) <id>

        \(flag.summary(on))
        """
    }

    static func run(_ args: [String], pinned: Bool, context: CLIContext) async {
        await run(args, flag: .pin, on: pinned, context: context)
    }

    static func run(_ args: [String], flag: Flag, on: Bool, context: CLIContext) async {
        let parsed = ArgParser.parse(args, usage: usage(flag, on: on))
        let id = parsed.requiredID(commandName: flag.verb(on))

        let changed = await CLI.run {
            let store = try context.makeStore()
            switch flag {
            case .pin: return try await store.setPinned(on, id: id)
            case .favorite: return try await store.setFavorite(on, id: id)
            }
        }
        guard changed else {
            CLI.fail("entry \(id) not found")
        }
        Notify.storeChanged()
        print("\(flag.pastTense(on)) entry \(id).")
    }
}
