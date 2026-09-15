import Foundation

// MARK: - JSON repair
//
// Best-effort transformation of common broken-JSON patterns into valid JSON.
// Design guarantees (edge cases drawn from jsonlint-core's hardening notes):
// - String-aware: NOTHING inside a double-quoted string is ever transformed
//   (a trailing comma inside "a,}" or an apostrophe in "it's" is safe).
// - Escape-aware: \" inside strings does not terminate them.
// - Every fix is reported, and the result is re-validated as JSON before it
//   is returned; if it still doesn't parse, repair returns nil.

public struct JSONRepairResult: Sendable, Equatable {
    public let repaired: String
    /// Human-readable labels of the fixes applied, in application order.
    public let fixes: [String]
}

public enum JSONRepair {

    /// Attempts to repair `text` into valid JSON. Returns nil when no fix
    /// applies or the result still fails validation.
    public static func repair(_ text: String) -> JSONRepairResult? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var strippedBOM = false
        if body.hasPrefix("\u{FEFF}") {
            body.removeFirst()
            strippedBOM = true
        }
        // Cheap pre-filter only — leading comments/BOM are stripped by the
        // scanner; the final gate does the real validation.
        guard body.contains("{") || body.contains("[") else { return nil }

        var fixes: [String] = []
        if strippedBOM { fixes.append("stripped byte-order mark") }

        let scanned = scanPhase(body, fixes: &fixes)
        let repaired = transformOutsideStrings(scanned.output,
                                               stringRanges: scanned.stringRanges) {
            transformSegment($0, fixes: &fixes)
        }

        // Final gate: must now be valid JSON, and must actually differ.
        guard JSONData.parse(repaired) != nil, repaired != text else { return nil }
        var seen = Set<String>()
        let uniqueFixes = fixes.filter { seen.insert($0).inserted }
        return JSONRepairResult(repaired: repaired, fixes: uniqueFixes)
    }

    // MARK: - Phase 1: scanner

    /// Strips comments, normalizes smart quotes, converts single-quoted
    /// strings, and records the double-quoted string ranges of the output.
    private static func scanPhase(
        _ body: String, fixes: inout [String]
    ) -> (output: String, stringRanges: [Range<Int>]) {
        var out: [Character] = []
        out.reserveCapacity(body.count)
        var stringRanges: [Range<Int>] = []
        var inString = false
        var stringStart = 0
        var inLineComment = false
        var inBlockComment = false
        var strippedComments = false
        var smartQuotesFixed = false
        var singleQuotesFixed = false

        var i = body.startIndex
        while i < body.endIndex {
            let ch = body[i]

            if inString {
                i = scanStringChar(ch, body: body, i: i, out: &out,
                                   stringStart: stringStart, stringRanges: &stringRanges,
                                   inString: &inString)
                continue
            }

            switch scanComment(ch, body: body, i: i,
                               inLineComment: &inLineComment,
                               inBlockComment: &inBlockComment,
                               stripped: &strippedComments) {
            case .skipped(let next):
                i = next
                continue
            case .newlineEmitted:
                out.append("\n")
                i = body.index(after: i)
                continue
            case .notComment:
                break
            }

            switch ch {
            case "\"":
                inString = true
                stringStart = out.count
                out.append(ch)
            case "“", "”":
                smartQuotesFixed = true
                inString = true
                stringStart = out.count
                out.append("\"")
            case "‘":
                smartQuotesFixed = true
                out.append("'")
            case "'":
                if let close = closingSingleQuote(body, from: body.index(after: i)) {
                    singleQuotesFixed = true
                    i = convertSingleQuoted(body, open: i, close: close,
                                            out: &out, stringStart: out.count,
                                            stringRanges: &stringRanges)
                    continue
                } else {
                    out.append(ch)
                }
            default:
                out.append(ch)
            }
            i = body.index(after: i)
        }

        if strippedComments { fixes.append("removed comments") }
        if smartQuotesFixed { fixes.append("converted smart quotes") }
        if singleQuotesFixed { fixes.append("normalized single-quoted strings") }
        return (String(out), stringRanges)
    }

    private enum CommentScan {
        case notComment
        case skipped(String.Index)
        case newlineEmitted
    }

    /// Handles comment state for the scanner.
    private static func scanComment(
        _ ch: Character, body: String, i: String.Index,
        inLineComment: inout Bool, inBlockComment: inout Bool, stripped: inout Bool
    ) -> CommentScan {
        if inLineComment {
            if ch == "\n" { inLineComment = false; return .newlineEmitted }
            stripped = true
            return .skipped(body.index(after: i))
        }
        if inBlockComment {
            stripped = true
            if ch == "*", body.index(after: i) < body.endIndex,
               body[body.index(after: i)] == "/" {
                inBlockComment = false
                return .skipped(body.index(i, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex)
            }
            return .skipped(body.index(after: i))
        }
        guard ch == "/", body.index(after: i) < body.endIndex else { return .notComment }
        let next = body[body.index(after: i)]
        if next == "/" {
            inLineComment = true
            stripped = true
            return .skipped(body.index(i, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex)
        }
        if next == "*" {
            inBlockComment = true
            stripped = true
            return .skipped(body.index(i, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex)
        }
        return .notComment
    }

    /// Consumes one character inside a double-quoted string. Returns the next
    /// index. Smart closers terminate the string as ASCII quotes.
    private static func scanStringChar(
        _ ch: Character, body: String, i: String.Index, out: inout [Character],
        stringStart: Int, stringRanges: inout [Range<Int>], inString: inout Bool
    ) -> String.Index {
        if ch == "\\", i < body.index(before: body.endIndex) {
            let next = body.index(after: i)
            out.append(ch)
            out.append(body[next])
            return body.index(after: next)
        }
        out.append(ch == "“" || ch == "”" ? "\"" : ch)
        if ch == "\"" || ch == "“" || ch == "”" {
            stringRanges.append(stringStart..<out.count - 1)
            inString = false
        }
        return body.index(after: i)
    }

    /// Converts a single-quoted span to double quotes (escaping inner `"`).
    /// Returns the index just past the closing quote.
    private static func convertSingleQuoted(
        _ body: String, open: String.Index, close: String.Index,
        out: inout [Character], stringStart: Int, stringRanges: inout [Range<Int>]
    ) -> String.Index {
        out.append("\"")
        var j = body.index(after: open)
        while j < close {
            let c = body[j]
            if c == "\"" { out.append("\\") }
            out.append(c)
            j = body.index(after: j)
        }
        out.append("\"")
        stringRanges.append(stringStart..<out.count - 1)
        return body.index(after: close)
    }

    /// Finds a closing single quote for a single-quoted string: same line,
    /// no double quote in between (that would be an apostrophe).
    private static func closingSingleQuote(_ text: String, from: String.Index) -> String.Index? {
        var j = from
        while j < text.endIndex {
            let c = text[j]
            if c == "\n" || c == "\"" { return nil }
            if c == "'" { return j }
            j = text.index(after: j)
        }
        return nil
    }

    // MARK: - Phase 2: outside-string transforms

    /// Applies `transform` to every segment OUTSIDE the double-quoted string
    /// ranges, reassembling the string afterwards.
    private static func transformOutsideStrings(
        _ input: String, stringRanges: [Range<Int>], transform: (String) -> String
    ) -> String {
        let chars = Array(input)
        var result: [Character] = []
        var cursor = 0

        for stringRange in stringRanges {
            let upper = min(stringRange.upperBound, chars.count)
            if cursor < stringRange.lowerBound {
                result.append(contentsOf: transform(String(chars[cursor..<stringRange.lowerBound])))
            }
            result.append(contentsOf: chars[stringRange.lowerBound..<upper])
            cursor = max(cursor, upper)
        }
        if cursor < chars.count {
            result.append(contentsOf: transform(String(chars[cursor...])))
        }
        return String(result)
    }

    // MARK: - Phase 2 transforms (one segment)

    private static func transformSegment(
        _ segment: String, fixes: inout [String]
    ) -> String {
        var s = segment
        s = replaceWordBoundaries(s) { word in
            switch word {
            case "True": return "true"
            case "False": return "false"
            case "None", "undefined", "NaN", "Infinity", "-Infinity": return "null"
            default: return nil
            }
        }
        if s != segment { fixes.append("converted Python/JS literals") }

        if convertHexNumbers(&s) { fixes.append("converted hexadecimal numbers") }
        if quoteBareKeys(&s) { fixes.append("quoted bare keys") }
        if removeTrailingCommas(&s) { fixes.append("removed trailing commas") }
        return s
    }

    private static func replaceWordBoundaries(
        _ input: String, _ replacement: (String) -> String?
    ) -> String {
        var result = ""
        var word = ""
        for ch in input {
            if ch.isLetter || ch.isNumber || ch == "_" {
                word.append(ch)
            } else {
                result.append(contentsOf: replacement(word) ?? word)
                word = ""
                result.append(ch)
            }
        }
        result.append(contentsOf: replacement(word) ?? word)
        return result
    }

    private static func convertHexNumbers(_ input: inout String) -> Bool {
        var fixed = false
        var result = ""
        var i = input.startIndex
        while i < input.endIndex {
            if input[i] == "0", input.index(after: i) < input.endIndex,
               "xX".contains(input[input.index(after: i)]) {
                var j = input.index(i, offsetBy: 2)
                var hex = ""
                while j < input.endIndex, input[j].isHexDigit {
                    hex.append(input[j])
                    j = input.index(after: j)
                }
                if !hex.isEmpty, let value = Int(hex, radix: 16),
                   i == input.startIndex || !isWordChar(input[input.index(before: i)]),
                   j == input.endIndex || !isWordChar(input[j]) {
                    result += String(value)
                    fixed = true
                    i = j
                    continue
                }
            }
            result.append(input[i])
            i = input.index(after: i)
        }
        if fixed { input = result }
        return fixed
    }

    private static func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_"
    }

    private static func quoteBareKeys(_ input: inout String) -> Bool {
        var chars = Array(input)
        var fixed = false
        var i = 0
        while i < chars.count {
            if chars[i] == "{" || chars[i] == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, isKeyStart(chars[j]) {
                    var k = j
                    while k < chars.count, isKeyChar(chars[k]) { k += 1 }
                    if k > j {
                        var m = k
                        while m < chars.count, chars[m].isWhitespace { m += 1 }
                        if m < chars.count, chars[m] == ":" {
                            chars.insert("\"", at: j)
                            chars.insert("\"", at: k + 1)
                            fixed = true
                            i = k + 2
                            continue
                        }
                    }
                }
            }
            i += 1
        }
        if fixed { input = String(chars) }
        return fixed
    }

    private static func isKeyStart(_ ch: Character) -> Bool {
        ch.isLetter || ch == "_" || ch == "$"
    }

    private static func isKeyChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_" || ch == "$"
    }

    private static func removeTrailingCommas(_ input: inout String) -> Bool {
        let chars = Array(input)
        var result: [Character] = []
        var fixed = false
        var i = 0
        while i < chars.count {
            if chars[i] == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" {
                    fixed = true
                    i += 1
                    continue
                }
            }
            result.append(chars[i])
            i += 1
        }
        if fixed { input = String(result) }
        return fixed
    }
}
