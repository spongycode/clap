import Foundation
import ClapCore

enum ConfigCommand {
    static let usage = """
    Usage: clap config get [key]
           clap config set <key> <value>

    Keys:
      text.max_entries    positive integer (default 100000)
      text.max_size       bytes or human size, e.g. 50MB (default 50MB)
      image.max_entries   positive integer (default 500)
      image.max_size      bytes or human size, e.g. 100MB (default 100MB)
      shell.enabled       true/false or 1/0 (default true)
      shell.max_entries   positive integer (default 50000)
      shell.max_size      bytes or human size, e.g. 10MB (default 10MB)
      shell.histfile      path to history file, or empty string for auto-detect
      monitoring.paused   true/false or 1/0 (default false)
      exclusions          JSON array of bundle ids, e.g. ["com.apple.keychainaccess"]
      retention.days      non-negative integer, 0 = keep forever (default 0)
      launch_at_login     true/false or 1/0 (default false)
      paste.on_copy       true/false or 1/0 (default true) — paste into the
                          active app when selecting an entry in the UI
    """

    static let knownKeys: Set<String> = [
        "text.max_entries", "text.max_size",
        "image.max_entries", "image.max_size",
        "shell.enabled", "shell.max_entries", "shell.max_size", "shell.histfile",
        "monitoring.paused", "exclusions",
        "retention.days", "launch_at_login",
        "paste.on_copy",
    ]

    static func run(_ args: [String], context: CLIContext) async {
        let parsed = ArgParser.parse(args, usage: usage)
        guard let action = parsed.positionals.first else {
            CLI.usageError("config requires 'get' or 'set'", usage: usage)
        }
        let rest = Array(parsed.positionals.dropFirst())
        switch action {
        case "get":
            guard rest.count <= 1 else {
                CLI.usageError("config get takes at most one key", usage: usage)
            }
            await get(key: rest.first, context: context)
        case "set":
            guard rest.count == 2 else {
                CLI.usageError("config set requires <key> <value>", usage: usage)
            }
            await set(key: rest[0], rawValue: rest[1], context: context)
        default:
            CLI.usageError("unknown config action '\(action)'", usage: usage)
        }
    }

    // MARK: - get

    private static func get(key: String?, context: CLIContext) async {
        if let key {
            let value = await CLI.run {
                let store = try context.makeStore()
                return try await store.config(key)
            }
            guard let value else {
                CLI.fail("unknown config key '\(key)'")
            }
            print(value)
            return
        }
        let all = await CLI.run {
            let store = try context.makeStore()
            return try await store.allConfig()
        }
        for (key, value) in all {
            print("\(key) = \(value)\(humanSuffix(key: key, value: value))")
        }
    }

    /// Size keys also get a human-readable rendering in parens.
    private static func humanSuffix(key: String, value: String) -> String {
        guard key.hasSuffix(".max_size"), let bytes = Int64(value) else { return "" }
        return " (\(ByteSize.format(bytes)))"
    }

    // MARK: - set

    private static func set(key: String, rawValue: String, context: CLIContext) async {
        guard knownKeys.contains(key) else {
            CLI.usageError("unknown config key '\(key)'", usage: usage)
        }
        let stored = validatedValue(key: key, rawValue: rawValue)
        await CLI.run {
            let store = try context.makeStore()
            try await store.setConfig(key, value: stored)
        }
        Notify.configChanged()
        print("\(key) = \(stored)\(humanSuffix(key: key, value: stored))")
    }

    /// Validates and canonicalizes the value for storage. Usage error (exit 2)
    /// on anything invalid.
    private static func validatedValue(key: String, rawValue: String) -> String {
        switch key {
        case "text.max_entries", "image.max_entries", "shell.max_entries":
            guard let n = Int(rawValue), n > 0 else {
                CLI.usageError("\(key) must be a positive integer", usage: usage)
            }
            return String(n)
        case "text.max_size", "image.max_size", "shell.max_size":
            guard let bytes = ByteSize.parse(rawValue), bytes > 0 else {
                CLI.usageError("\(key) must be a size like 52428800, 50MB or 1.5GB", usage: usage)
            }
            return String(bytes)
        case "monitoring.paused", "launch_at_login", "paste.on_copy", "shell.enabled":
            switch rawValue.lowercased() {
            case "true", "1": return "1"
            case "false", "0": return "0"
            default:
                CLI.usageError("\(key) must be true/false or 1/0", usage: usage)
            }
        case "shell.histfile":
            return rawValue.trimmingCharacters(in: .whitespaces)
        case "retention.days":
            guard let n = Int(rawValue), n >= 0 else {
                CLI.usageError("retention.days must be a non-negative integer", usage: usage)
            }
            return String(n)
        case "exclusions":
            guard let data = rawValue.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String].self, from: data) else {
                CLI.usageError("exclusions must be a JSON array of strings, e.g. [\"com.example.app\"]",
                               usage: usage)
            }
            // Re-encode canonically.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = (try? encoder.encode(parsed)) ?? Data("[]".utf8)
            return String(decoding: encoded, as: UTF8.self)
        default:
            CLI.usageError("unknown config key '\(key)'", usage: usage)
        }
    }
}
