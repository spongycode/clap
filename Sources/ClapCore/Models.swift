import Foundation

public enum EntryType: String, Codable, Sendable, CaseIterable { case text, image, shell }

public struct ClipboardEntry: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let type: EntryType
    public let content: String?        // normalized text
    public let imagePath: String?      // relative path under images/
    public let imageFormat: String?
    public let contentHash: String
    public let createdAt: Date
    public let lastUsedAt: Date
    public let sizeBytes: Int64
    public let isPinned: Bool
    public let useCount: Int
    public let sourceApp: String?
}

public struct SearchQuery: Sendable {
    public var text: String?           // FTS terms / phrase (quoted)
    public var regex: String?          // regex pattern (mutually exclusive with text)
    public var type: EntryType?        // nil = no single-type filter
    /// Multi-type filter (nil = all types). When `type` is set it wins.
    /// Used by the UI: the Classic tab shows text+image but not shell.
    public var types: Set<EntryType>?
    public var pinnedOnly: Bool
    public var limit: Int
    public var offset: Int

    public init(text: String? = nil, regex: String? = nil, type: EntryType? = nil,
                types: Set<EntryType>? = nil,
                pinnedOnly: Bool = false, limit: Int = 100, offset: Int = 0) {
        self.text = text
        self.regex = regex
        self.type = type
        self.types = types
        self.pinnedOnly = pinnedOnly
        self.limit = limit
        self.offset = offset
    }

    /// The effective type filter: single `type` wins, else `types`, else nil.
    public var effectiveTypes: Set<EntryType>? {
        if let type { return [type] }
        return types
    }

    /// Parses UI/CLI query syntax: bare terms, "quoted phrase",
    /// `regex:<pat>`, `type:text|image`. Unknown filters ignored.
    /// If both regex and text are present, regex wins and text is ignored.
    public static func parse(_ raw: String, limit: Int, offset: Int) -> SearchQuery {
        let tokens = QueryTokenizer.tokenize(raw)
        var type: EntryType?
        var regex: String?
        var textTokens: [QueryTokenizer.Token] = []

        for token in tokens {
            if !token.quoted, token.value.lowercased().hasPrefix("type:") {
                switch token.value.dropFirst(5).lowercased() {
                case "text": type = .text
                case "image": type = .image
                case "shell": type = .shell
                default: break // unknown filter value ignored
                }
                continue
            }
            if !token.quoted, token.value.lowercased().hasPrefix("regex:") {
                if regex == nil { regex = String(token.value.dropFirst(6)) }
                continue
            }
            textTokens.append(token)
        }

        // When regex: is the only filter and leads the query, the whole
        // remainder of the raw string after "regex:" is the pattern
        // (allows patterns containing spaces).
        if regex != nil, type == nil {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("regex:") {
                regex = String(trimmed.dropFirst(6))
            }
        }

        var text: String?
        if regex == nil, !textTokens.isEmpty {
            text = textTokens
                .map { $0.quoted ? "\"\($0.value)\"" : $0.value }
                .joined(separator: " ")
        }
        return SearchQuery(text: text, regex: regex, type: type,
                           pinnedOnly: false, limit: limit, offset: offset)
    }
}

public struct StoreStats: Sendable {
    public let textCount: Int, imageCount: Int, shellCount: Int
    public let textBytes: Int64, imageBytes: Int64, shellBytes: Int64
    public let pinnedCount: Int
    public let eventsToday: Int, duplicatesAvoidedToday: Int
    public let oldestEntry: Date?
}

/// Splits a query string into whitespace-separated tokens, honoring
/// double-quoted phrases (which may contain whitespace).
enum QueryTokenizer {
    struct Token: Equatable {
        let value: String
        let quoted: Bool
    }

    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false

        func flush(quoted: Bool) {
            if !current.isEmpty { tokens.append(Token(value: current, quoted: quoted)) }
            current = ""
        }

        for ch in s {
            if ch == "\"" {
                if inQuotes {
                    flush(quoted: true)
                    inQuotes = false
                } else {
                    flush(quoted: false)
                    inQuotes = true
                }
            } else if ch.isWhitespace && !inQuotes {
                flush(quoted: false)
            } else {
                current.append(ch)
            }
        }
        flush(quoted: false) // unterminated quote: treat as in-progress prefix query
        return tokens
    }
}
