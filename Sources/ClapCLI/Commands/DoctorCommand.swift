import Foundation
import ClapCore

enum DoctorCommand {
    static let usage = """
    Usage: clap doctor

    Runs health checks on the data directory, database and background app.
    Exits 1 when any check fails.
    """

    static func run(_ args: [String], context: CLIContext) async {
        let parsed = ArgParser.parse(args, usage: usage)
        guard parsed.positionals.isEmpty else {
            CLI.usageError("unexpected argument '\(parsed.positionals[0])'", usage: usage)
        }

        var checks = ClipboardStore.doctorChecks(dataDir: context.dataDir)
        let appRunning = AppProcess.isRunning()
        checks.append(("Background process", appRunning,
                       appRunning ? "ClapApp is running"
                                  : "ClapApp is not running — start it to capture clipboard changes"))

        var anyFailed = false
        for check in checks {
            print("\(check.ok ? "✓" : "✗") \(check.name) — \(check.detail)")
            if !check.ok { anyFailed = true }
        }
        exit(anyFailed ? ExitCode.failure : ExitCode.ok)
    }
}
