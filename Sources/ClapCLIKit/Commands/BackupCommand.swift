import Foundation
import ClapCore

/// `clap backup <dir>` — export full history (backup.json + images/).
/// `clap restore <dir>` — import a backup directory. Duplicates merge.
enum BackupCommand {
    enum Mode {
        case backup, restore
    }

    static let usage = """
    Usage: clap backup <directory>
           clap restore <directory>

    backup   Export the full history to <directory>/backup.json plus an
            images/ folder. Zip it and it travels anywhere.
    restore  Import a backup directory produced by `clap backup`.
            Duplicates merge; nothing is deleted.
    """

    static func run(_ args: [String], mode: Mode, context: CLIContext) async {
        let parsed = ArgParser.parse(args, usage: usage)
        guard parsed.positionals.count == 1 else {
            CLI.usageError("backup/restore require exactly one directory path", usage: usage)
        }
        let rawPath = parsed.positionals[0]
        let directory = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath,
                            isDirectory: true)

        switch mode {
        case .backup:
            let count = await CLI.run {
                let store = try context.makeStore()
                let exported = try await store.exportBackup(to: directory)
                return exported
            }
            print("Exported \(count) entries to \(directory.path)")

        case .restore:
            let result = await CLI.run {
                let store = try context.makeStore()
                return try await store.importBackup(from: directory)
            }
            Notify.storeChanged()
            print("Restored \(result.imported) entries (\(result.merged) merged, \(result.skipped) skipped).")
        }
    }
}
