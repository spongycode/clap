import Foundation

/// clap — clipboard manager CLI dispatcher.
///
/// Hand-rolled argument parsing, no external dependencies.
/// Global flags (`--data-dir <path>`) are accepted anywhere on the line and
/// extracted before command dispatch.
public enum ClapCLI {
    public static let version = "0.2.0"

    /// Command dispatch table. Hidden/scripting commands are marked in help
    /// comments only.
    private static let commands: [String: ([String], CLIContext) async -> Void] = [
        "list": { await ListCommand.run($0, context: $1) },
        "search": { await SearchCommand.run($0, context: $1) },
        "get": { await GetCommand.run($0, context: $1) },
        "copy": { await CopyCommand.run($0, context: $1) },
        "delete": { await DeleteCommand.run($0, context: $1) },
        "out": { await DeleteCommand.runOutAlias($0, context: $1) },
        "pin": { await PinCommand.run($0, pinned: true, context: $1) },
        "unpin": { await PinCommand.run($0, pinned: false, context: $1) },
        "tag": { await TagCommand.run($0, context: $1) },
        "tags": { await TagCommand.run(["list"] + $0, context: $1) },
        "clear": { await ClearCommand.run($0, context: $1) },
        "stats": { await StatsCommand.run($0, context: $1) },
        "config": { await ConfigCommand.run($0, context: $1) },
        "doctor": { await DoctorCommand.run($0, context: $1) },
        "import": { await ImportCommand.run($0, context: $1) },
        "pause": { await PauseCommand.run($0, paused: true, context: $1) },
        "resume": { await PauseCommand.run($0, paused: false, context: $1) },
        // Hidden: seeds the store for testing/scripting. Not in help.
        "_capture": { await CaptureCommand.run($0, context: $1) },
        // Hidden: runs eviction/retention/vacuum like the app's workers.
        "_maintain": { await MaintainCommand.run($0, context: $1) }
    ]

    public static func main(arguments: [String] = Array(CommandLine.arguments.dropFirst())) async {
        var args = arguments
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
        default:
            guard let handler = commands[command] else {
                CLI.usageError("unknown command '\(command)'", usage: HelpText.overview)
            }
            await handler(args, context)
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
    clap \(ClapCLI.version) — native macOS clipboard manager CLI

    Usage:
      clap                                                  Open the clipboard UI (asks ClapApp)
      clap list [--images] [--shell] [--tag <tag>] [--limit N] [--offset N] [--json]
      clap search <query> [--regex <pat>] [--type text|image|shell] [--tag <tag>] [--limit N] [--offset N] [--json]
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
