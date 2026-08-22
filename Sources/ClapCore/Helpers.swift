import Foundation
import CryptoKit
import UniformTypeIdentifiers

public enum TextSummaries {
    /// Collapses all whitespace runs and control characters to single spaces,
    /// trims, then truncates to `maxChars` appending an ellipsis when cut.
    public static func singleLine(_ s: String, maxChars: Int) -> String {
        guard !s.isEmpty else { return "" }
        let maxScan = max(maxChars * 4, 1000)
        let prefixSlice = s.count > maxScan ? s.prefix(maxScan) : s[...]
        var collapsed = ""
        var previousWasSpace = true
        var nonSpaceCount = 0
        for scalar in prefixSlice.unicodeScalars {
            if scalar.properties.isWhitespace || scalar.value < 0x20 || scalar.value == 0x7f {
                if !previousWasSpace {
                    collapsed.unicodeScalars.append(" ")
                    previousWasSpace = true
                }
            } else {
                collapsed.unicodeScalars.append(scalar)
                previousWasSpace = false
                nonSpaceCount += 1
                if nonSpaceCount >= maxChars + 1 {
                    break
                }
            }
        }
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        if s.count > maxChars || trimmed.count > maxChars {
            let cutoff = trimmed.index(trimmed.startIndex, offsetBy: min(trimmed.count, maxChars))
            return String(trimmed[..<cutoff]) + "…"
        }
        return trimmed
    }

    /// Compact relative time: "now", "5m", "2h", "3d", "2w", "3mo", "1y".
    public static func relativeTime(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        let elapsed = interval >= 0 ? interval : -interval
        let suffix = interval >= 0 ? "" : "?"
        if elapsed < 60 { return "now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m\(suffix)" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600))h\(suffix)" }
        if elapsed < 7 * 86_400 { return "\(Int(elapsed / 86_400))d\(suffix)" }
        if elapsed < 30 * 86_400 { return "\(max(1, Int(elapsed / (7 * 86_400))))w\(suffix)" }
        if elapsed < 365 * 86_400 { return "\(max(1, Int(elapsed / (30 * 86_400))))mo\(suffix)" }
        return "\(max(1, Int(elapsed / (365 * 86_400))))y\(suffix)"
    }
}

public enum ImageFormats {
    private static let explicit: [String: String] = [
        "png": "public.png",
        "jpeg": "public.jpeg",
        "jpg": "public.jpeg",
        "tiff": "public.tiff",
        "tif": "public.tiff",
        "gif": "com.compuserve.gif",
        "bmp": "com.microsoft.bmp",
        "webp": "org.webpproject.webp",
        "heic": "public.heic"
    ]

    /// Maps a stored image format ("png", "jpeg", ...) to its UTI identifier.
    /// Returns nil for unknown formats so callers can apply their own
    /// fallback (e.g. TIFF conversion).
    public static func uti(forFormat format: String) -> String? {
        explicit[format.lowercased()]
    }
}

public enum TextNormalizer {
    /// Trims leading/trailing whitespace and newlines. Interior whitespace
    /// is never modified.
    public static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ContentHasher {
    /// FNV-1a 64-bit over UTF-8 bytes, lowercase hex, 16 chars.
    public static func textHash(_ normalized: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV offset basis
        let prime: UInt64 = 0x0000_0100_0000_01b3 // FNV prime
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }

    /// SHA256 hex (lowercase) of raw image bytes.
    public static func imageHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ByteSize {
    /// Parses "1024", "50MB", "1.5GB", "100kb" (case-insensitive; KB/MB/GB
    /// with optional trailing B). Returns nil for anything unparseable.
    public static func parse(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // Order matters: longest suffixes first.
        let suffixes: [(String, Int64)] = [
            ("gb", 1 << 30), ("mb", 1 << 20), ("kb", 1 << 10),
            ("g", 1 << 30), ("m", 1 << 20), ("k", 1 << 10), ("b", 1)
        ]
        var numberPart = trimmed
        var multiplier: Int64 = 1
        for (suffix, m) in suffixes where trimmed.hasSuffix(suffix) {
            numberPart = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            multiplier = m
            break
        }
        guard let value = Double(numberPart), value.isFinite, value >= 0 else { return nil }
        let bytes = value * Double(multiplier)
        guard bytes < Double(Int64.max) else { return nil }
        return Int64(bytes.rounded())
    }

    /// Formats bytes as "512 B", "1.0 KB", "18.2 MB", "1.5 GB", ...
    public static func format(_ bytes: Int64) -> String {
        guard bytes >= 1024 else { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unitIndex = -1
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

public enum SafeRegex {
    static let maxPatternLength = 1000
    static let maxInputLength = 10_000

    /// Compiles an NSRegularExpression. Rejects patterns longer than 1000
    /// characters. Invalid pattern -> ClapCoreError.invalidPattern.
    ///
    /// Case-insensitive by default: clipboard search is a recall tool, and
    /// `regex:get.*extra` should find "getParcelableExtra". Prefix the
    /// pattern with `(?-i)` to opt back into exact-case matching.
    public static func compile(_ pattern: String) throws -> NSRegularExpression {
        guard pattern.count <= maxPatternLength else {
            throw ClapCoreError.invalidPattern("pattern exceeds \(maxPatternLength) characters")
        }
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            // Fixed reason only: NSError's description embeds the pattern
            // itself, which is user search input and must not end up in any
            // log a caller might write this error to.
            throw ClapCoreError.invalidPattern("pattern failed to compile")
        }
    }

    /// Matching over a bounded slice (first 10,000 characters) so pathological
    /// patterns cannot blow up on huge clipboard entries. Never throws.
    static func matches(_ regex: NSRegularExpression, in content: String) -> Bool {
        let slice = content.count > maxInputLength ? String(content.prefix(maxInputLength)) : content
        let range = NSRange(slice.startIndex..<slice.endIndex, in: slice)
        return regex.firstMatch(in: slice, options: [], range: range) != nil
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
