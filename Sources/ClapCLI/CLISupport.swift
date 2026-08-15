import Foundation
import Darwin
import ClapCore

/// Shared per-invocation context: the resolved `--data-dir` override (nil means
/// CLAP_DATA_DIR / default resolution inside ClapCore).
struct CLIContext {
    let dataDir: URL?

    func makeStore() throws -> ClipboardStore {
        try ClipboardStore(dataDir: dataDir)
    }
}

enum ExitCode {
    static let ok: Int32 = 0
    static let failure: Int32 = 1   // not found / no match / doctor failure
    static let usage: Int32 = 2     // bad flag, bad value, unknown command
}

enum CLI {
    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func usageError(_ message: String, usage: String? = nil) -> Never {
        printError("clap: \(message)")
        if let usage { printError(usage) }
        exit(ExitCode.usage)
    }

    static func fail(_ message: String, code: Int32 = ExitCode.failure) -> Never {
        printError("clap: \(message)")
        exit(code)
    }

    static var stdoutIsTTY: Bool { isatty(1) == 1 }

    /// Runs a throwing async body, mapping errors to exit codes.
    /// Invalid regex -> exit 2; anything else -> exit 1. Never a stack trace.
    static func run<T>(_ body: () async throws -> T) async -> T {
        do {
            return try await body()
        } catch ClapCoreError.invalidPattern {
            printError("clap: Invalid regular expression")
            exit(ExitCode.usage)
        } catch let error as ClapCoreError {
            fail("\(error)")
        } catch {
            fail(error.localizedDescription)
        }
    }
}

/// Minimal flag parser for one subcommand. Supports `--flag`, `--flag value`,
/// `--flag=value`, `-h/--help` (prints the given usage and exits 0). Any other
/// leading-dash token is a usage error; the rest are positionals.
struct ArgParser {
    private(set) var positionals: [String] = []
    private var bools: Set<String> = []
    private var values: [String: String] = [:]
    private let usage: String

    private init(usage: String) { self.usage = usage }

    static func parse(_ args: [String],
                      boolFlags: Set<String> = [],
                      valueFlags: Set<String> = [],
                      usage: String) -> ArgParser {
        var parser = ArgParser(usage: usage)
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--help" || arg == "-h" {
                print(usage)
                exit(ExitCode.ok)
            }
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                let name = String(arg[..<eq])
                if valueFlags.contains(name) {
                    parser.values[name] = String(arg[arg.index(after: eq)...])
                    i += 1
                    continue
                }
            }
            if boolFlags.contains(arg) {
                parser.bools.insert(arg)
                i += 1
                continue
            }
            if valueFlags.contains(arg) {
                guard i + 1 < args.count else {
                    CLI.usageError("\(arg) requires a value", usage: usage)
                }
                parser.values[arg] = args[i + 1]
                i += 2
                continue
            }
            // Tokens like "-3" are values, not flags.
            if arg.hasPrefix("-"), arg != "-", !(arg.dropFirst().first?.isNumber ?? false) {
                CLI.usageError("unknown option '\(arg)'", usage: usage)
            }
            parser.positionals.append(arg)
            i += 1
        }
        return parser
    }

    func has(_ flag: String) -> Bool { bools.contains(flag) }
    func value(_ flag: String) -> String? { values[flag] }

    func int(_ flag: String, default def: Int, min minimum: Int) -> Int {
        guard let raw = values[flag] else { return def }
        guard let v = Int(raw), v >= minimum else {
            CLI.usageError("invalid value for \(flag): '\(raw)'", usage: usage)
        }
        return v
    }

    /// Requires a single positional numeric id.
    func requiredID(commandName: String) -> Int64 {
        guard positionals.count == 1, let id = Int64(positionals[0]), id > 0 else {
            CLI.usageError("\(commandName) requires a numeric entry id", usage: usage)
        }
        return id
    }
}

/// Distributed notifications (IPC with ClapApp). Names are the binding
/// contract in ARCHITECTURE.md.
enum Notify {
    static let openUIName = "com.spongycode.clap.openUI"
    static let storeChangedName = "com.spongycode.clap.storeChanged"
    static let configChangedName = "com.spongycode.clap.configChanged"

    private static func post(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    }

    static func openUI() { post(openUIName) }
    static func storeChanged() { post(storeChangedName) }
    static func configChanged() { post(configChangedName) }
}

/// Detection of the background app process.
enum AppProcess {
    static let bundleID = "com.spongycode.clap"

    static func isRunning() -> Bool {
        if runningViaWorkspace() { return true }
        return runningViaPgrep()
    }

    private static func runningViaWorkspace() -> Bool {
        // NSWorkspace lives in AppKit; keep it out of this file so only
        // copy/open link AppKit symbols. Implemented in OpenCommand.swift.
        WorkspaceProbe.isAppRunning(bundleID: bundleID)
    }

    private static func runningViaPgrep() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "ClapApp"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
