import Foundation
import ClapCore

/// clap — clipboard manager CLI entry point.
///
/// Hand-rolled argument parsing, no external dependencies.
/// Global flags (`--data-dir <path>`) are accepted anywhere on the line and
/// extracted before command dispatch.
@main
struct ClapMain {
    static let version = "0.2.0"

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let dataDir = extractDataDir(&args)
        let context = CLIContext(dataDir: dataDir)

        guard !args.isEmpty else {
            OpenCommand.run(context: context)
            return
        }

        let command = args.removeFirst()
        switch command {
        case "--help", "-h", "help":
            print(HelpText.overview)
        case "--version", "version":
            print("clap \(version)")
        case "list":
            await ListCommand.run(args, context: context)
        case "search":
            await SearchCommand.run(args, context: context)
        case "get":
            await GetCommand.run(args, context: context)
        case "copy":
            await CopyCommand.run(args, context: context)
        case "delete":
            await DeleteCommand.run(args, context: context)
        case "out":
            await DeleteCommand.runOutAlias(args, context: context)
        case "pin":
            await PinCommand.run(args, pinned: true, context: context)
        case "unpin":
            await PinCommand.run(args, pinned: false, context: context)
        case "tag":
            await TagCommand.run(args, context: context)
        case "tags":
            await TagCommand.run(["list"] + args, context: context)
        case "clear":
            await ClearCommand.run(args, context: context)
        case "stats":
            await StatsCommand.run(args, context: context)
        case "config":
            await ConfigCommand.run(args, context: context)
        case "doctor":
            await DoctorCommand.run(args, context: context)
        case "import":
            await ImportCommand.run(args, context: context)
        case "pause":
            await PauseCommand.run(args, paused: true, context: context)
        case "resume":
            await PauseCommand.run(args, paused: false, context: context)
        case "_capture":
            // Hidden: seeds the store for testing/scripting. Not in help.
            await CaptureCommand.run(args, context: context)
        case "_maintain":
            // Hidden: runs eviction/retention/vacuum like the app's workers.
            await MaintainCommand.run(args, context: context)
        default:
            CLI.usageError("unknown command '\(command)'", usage: HelpText.overview)
        }
    }

    /// Removes every `--data-dir <path>` / `--data-dir=<path>` occurrence from
    /// the argument list and returns the last one, expanded.
    private static func extractDataDir(_ args: inout [String]) -> URL? {
        var result: URL?
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--data-dir" {
                guard i + 1 < args.count else {
                    CLI.usageError("--data-dir requires a path", usage: HelpText.overview)
                }
                result = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath,
                             isDirectory: true)
                args.removeSubrange(i...(i + 1))
            } else if arg.hasPrefix("--data-dir=") {
                let raw = String(arg.dropFirst("--data-dir=".count))
                guard !raw.isEmpty else {
                    CLI.usageError("--data-dir requires a path", usage: HelpText.overview)
                }
                result = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath,
                             isDirectory: true)
                args.remove(at: i)
            } else {
                i += 1
            }
        }
        return result
    }
}

enum HelpText {
    static let overview = """
    clap \(ClapMain.version) — native macOS clipboard manager CLI

    Usage:
      clap                                                  Open the clipboard UI (asks ClapApp)
      clap list [--images] [--shell] [--limit N] [--offset N] [--json]
      clap search <query> [--regex <pat>] [--type text|image|shell] [--limit N] [--offset N] [--json]
      clap get <id> [--json]
      clap copy <id>
      clap delete <id> | --text <text> | --regex <pat>
      clap out [<id> | <exact text>]                        Alias for clap delete
      clap pin <id> / clap unpin <id>
      clap tag add <id> <tag> / clap tag remove <id> <tag>
      clap tags / clap tag list [id]
      clap clear [--force]
      clap stats [--json]
      clap config get [key]
      clap config set <key> <value>
      clap doctor
      clap import maccy|shell-history [--dry-run]
      clap pause / clap resume

    Global options:
      --data-dir <path>   Data directory (default: ~/Library/Application Support/clap,
                          or the CLAP_DATA_DIR environment variable)
      --help, -h          Help for clap or any subcommand
      --version           Print version

    Exit codes: 0 ok, 1 not found / no match, 2 usage error.
    """
}
