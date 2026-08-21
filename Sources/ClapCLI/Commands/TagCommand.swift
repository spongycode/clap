import Foundation
import ClapCore

enum TagCommand {
    static let usage = """
    Usage: clap tag <subcommand> [args]
           clap tags

    Manage tags and pinboards for clipboard entries.

    Subcommands:
      add <id> <tag>       Add a tag to an entry (e.g. 'clap tag add 42 work')
      remove <id> <tag>    Remove a tag from an entry
      set <id> <tags...>   Set exact list of tags for an entry
      list [id]            List all tags, or tags for a specific entry
      clap tags            Shortcut to list all tags and their counts
    """

    static func run(_ args: [String], context: CLIContext) async {
        guard !args.isEmpty else {
            await listAllTags(context: context)
            return
        }

        let subcommand = args[0].lowercased()
        let rest = Array(args.dropFirst())

        switch subcommand {
        case "add":
            guard rest.count >= 2, let id = Int64(rest[0]) else {
                CLI.usageError("clap tag add requires <id> and <tag>", usage: usage)
            }
            let tag = rest[1]
            await CLI.run {
                let store = try context.makeStore()
                let changed = try await store.addTag(tag, entryID: id)
                if changed {
                    print("Added tag '#\(tag.trimmingCharacters(in: CharacterSet(charactersIn: "#")))' to entry \(id).")
                } else {
                    print("Tag already present or invalid on entry \(id).")
                }
            }

        case "remove", "rm":
            guard rest.count >= 2, let id = Int64(rest[0]) else {
                CLI.usageError("clap tag remove requires <id> and <tag>", usage: usage)
            }
            let tag = rest[1]
            await CLI.run {
                let store = try context.makeStore()
                let changed = try await store.removeTag(tag, entryID: id)
                if changed {
                    print("Removed tag '#\(tag.trimmingCharacters(in: CharacterSet(charactersIn: "#")))' from entry \(id).")
                } else {
                    print("Tag not found on entry \(id).")
                }
            }

        case "set":
            guard rest.count >= 2, let id = Int64(rest[0]) else {
                CLI.usageError("clap tag set requires <id> and at least one <tag>", usage: usage)
            }
            let tags = Array(rest.dropFirst())
            await CLI.run {
                let store = try context.makeStore()
                try await store.setTags(tags, entryID: id)
                print("Updated tags for entry \(id): \(tags.map { "#\($0)" }.joined(separator: ", "))")
            }

        case "list", "ls":
            if let first = rest.first, let id = Int64(first) {
                await listTagsForEntry(id: id, context: context)
            } else {
                await listAllTags(context: context)
            }

        default:
            if let id = Int64(subcommand) {
                await listTagsForEntry(id: id, context: context)
            } else {
                CLI.usageError("unknown tag subcommand '\(subcommand)'", usage: usage)
            }
        }
    }

    private static func listAllTags(context: CLIContext) async {
        await CLI.run {
            let store = try context.makeStore()
            let all = try await store.allTags()
            guard !all.isEmpty else {
                print("No tags defined yet.")
                return
            }
            print("TAG".padding(toLength: 20, withPad: " ", startingAt: 0) + "ENTRIES")
            print(String(repeating: "─", count: 32))
            for item in all {
                let tagStr = "#\(item.tag)".padding(toLength: 20, withPad: " ", startingAt: 0)
                print("\(tagStr)\(item.count)")
            }
        }
    }

    private static func listTagsForEntry(id: Int64, context: CLIContext) async {
        await CLI.run {
            let store = try context.makeStore()
            let tags = try await store.tags(for: id)
            guard !tags.isEmpty else {
                print("No tags on entry \(id).")
                return
            }
            print("Tags on entry \(id): " + tags.map { "#\($0)" }.joined(separator: ", "))
        }
    }
}
