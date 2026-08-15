import Foundation
import ClapCore

/// Hidden command: `clap _maintain`. Runs the same maintenance pass as the
/// app's background workers (LRU eviction, retention, vacuum-if-needed).
/// Undocumented (not in help); used for testing and scripting.
enum MaintainCommand {
    static let usage = "Usage: clap _maintain"

    static func run(_ args: [String], context: CLIContext) async {
        _ = ArgParser.parse(args, usage: usage)
        let (evicted, expired) = await CLI.run { () -> (Int, Int) in
            let store = try context.makeStore()
            let evicted = try await store.enforceLimits()
            let expired = try await store.applyRetention()
            try await store.vacuumIfNeeded()
            return (evicted, expired)
        }
        if evicted + expired > 0 { Notify.storeChanged() }
        print("evicted=\(evicted) expired=\(expired)")
    }
}
