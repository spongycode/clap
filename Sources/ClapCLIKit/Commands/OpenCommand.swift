import Foundation
import AppKit

/// AppKit-backed process probe (NSWorkspace). Split out so CLISupport stays
/// Foundation-only.
enum WorkspaceProbe {
    static func isAppRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID
        }
    }
}

/// `clap` with no arguments: ask the background app to show the panel.
enum OpenCommand {
    static func run(context: CLIContext) {
        Notify.openUI()
        if AppProcess.isRunning() {
            return
        }
        // Not running: try to launch a ClapApp binary we can find.
        if let binary = findAppBinary() {
            do {
                try launchDetached(binary)
                print("ClapApp was not running — launched \(binary.path).")
                // Give it a moment to register its observer, then re-post.
                Thread.sleep(forTimeInterval: 0.5)
                Notify.openUI()
                return
            } catch {
                CLI.printError("clap: failed to launch \(binary.path): \(error.localizedDescription)")
            }
        }
        print("clap app is not running. Start ClapApp (or clap.app) to use the UI.")
        exit(ExitCode.failure)
    }

    /// Looks for the ClapApp binary next to our own executable only. Never
    /// searches the current directory — `clap` run from an untrusted cwd must
    /// not execute a binary that happens to be there.
    private static func findAppBinary() -> URL? {
        let candidate = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("ClapApp")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private static func launchDetached(_ binary: URL) throws {
        let process = Process()
        process.executableURL = binary
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Deliberately do not wait: the app keeps running after we exit.
    }
}
