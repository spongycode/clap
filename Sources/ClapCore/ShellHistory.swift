import Foundation

/// Parses zsh / bash history files.
///
/// zsh specifics handled here:
/// - "metafied" encoding: bytes >= 0x83 are stored as 0x83 followed by the
///   byte XOR 0x20 — must be undone before UTF-8 decoding (non-ASCII commands).
/// - EXTENDED_HISTORY lines: `: <start epoch>:<elapsed>;<command>`.
/// - Multiline commands: a line ending in a backslash continues on the next.
///
/// bash history is plain one-command-per-line (timestamps unavailable).
public enum ShellHistoryParser {

    public struct Command: Equatable, Sendable {
        public let text: String
        public let executedAt: Date?   // nil when the format has no timestamp
        public init(text: String, executedAt: Date?) {
            self.text = text
            self.executedAt = executedAt
        }
    }

    /// Reverses zsh's metafication. Safe on non-metafied input.
    public static func unmetafy(_ data: Data) -> Data {
        guard data.contains(0x83) else { return data }
        var out = Data(capacity: data.count)
        var i = data.startIndex
        while i < data.endIndex {
            let byte = data[i]
            if byte == 0x83, data.index(after: i) < data.endIndex {
                i = data.index(after: i)
                out.append(data[i] ^ 0x20)
            } else {
                out.append(byte)
            }
            i = data.index(after: i)
        }
        return out
    }

    /// Parses raw history-file bytes into commands, oldest first.
    /// Handles both extended and plain lines (files can mix them).
    public static func parse(_ raw: Data) -> [Command] {
        let data = unmetafy(raw)
        guard let content = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return [] }

        // Join zsh multiline continuations (trailing backslash).
        var logicalLines: [String] = []
        var pending: String?
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineString = String(line)
            if var current = pending {
                current += "\n" + lineString
                if lineString.hasSuffix("\\") {
                    pending = current
                } else {
                    logicalLines.append(current)
                    pending = nil
                }
            } else if lineString.hasSuffix("\\") {
                pending = lineString
            } else {
                logicalLines.append(lineString)
            }
        }
        if let pending { logicalLines.append(pending) }

        var commands: [Command] = []
        for line in logicalLines {
            guard let command = parseLine(line) else { continue }
            commands.append(command)
        }
        return commands
    }

    /// One logical line: extended `: <epoch>:<elapsed>;cmd` or plain `cmd`.
    static func parseLine(_ line: String) -> Command? {
        var text = line
        var date: Date?

        if line.hasPrefix(": "),
           let semicolon = line.firstIndex(of: ";") {
            let header = line[line.index(line.startIndex, offsetBy: 2)..<semicolon]
            let parts = header.split(separator: ":", maxSplits: 1)
            if let first = parts.first, let epoch = TimeInterval(first) {
                date = Date(timeIntervalSince1970: epoch)
                text = String(line[line.index(after: semicolon)...])
            }
        }

        // Undo the continuation backslashes zsh stores for multiline commands.
        text = text.replacingOccurrences(of: "\\\n", with: "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Command(text: text, executedAt: date)
    }

    /// Default history file resolution: zsh first (the macOS default shell),
    /// then bash. `HISTFILE` from the calling environment wins when set.
    public static func defaultHistoryFile() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["HISTFILE"], !env.isEmpty {
            let url = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
            if fm.fileExists(atPath: url.path) { return url }
        }
        let home = fm.homeDirectoryForCurrentUser
        for name in [".zsh_history", ".bash_history"] {
            let url = home.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
