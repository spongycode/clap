import Foundation

// MARK: - Clipboard content analysis shared by the app and CLI:
// color codes, case conversion, Base64/URL transforms, JWT and epoch parsing.

/// A parsed color code as normalized components (no AppKit dependency).
public struct ParsedColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public enum ColorParser {
    /// Parses hex (#RGB/#RGBA/#RRGGBB/#RRGGBBAA/0xRRGGBB), rgb()/rgba() and
    /// hsl()/hsla() strings. Returns nil for anything else.
    public static func parse(_ raw: String?) -> ParsedColor? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4 && text.count <= 40 else { return nil }

        // Hex formats: #RGB, #RGBA, #RRGGBB, #RRGGBBAA, 0xRRGGBB
        if text.hasPrefix("#") || text.hasPrefix("0x") {
            let hex = text.hasPrefix("#") ? String(text.dropFirst()) : String(text.dropFirst(2))
            guard let intVal = UInt64(hex, radix: 16) else { return nil }
            switch hex.count {
            case 3: // RGB
                return ParsedColor(
                    red: Double((intVal >> 8) & 0xF) / 15.0,
                    green: Double((intVal >> 4) & 0xF) / 15.0,
                    blue: Double(intVal & 0xF) / 15.0,
                    alpha: 1.0)
            case 4: // RGBA
                return ParsedColor(
                    red: Double((intVal >> 12) & 0xF) / 15.0,
                    green: Double((intVal >> 8) & 0xF) / 15.0,
                    blue: Double((intVal >> 4) & 0xF) / 15.0,
                    alpha: Double(intVal & 0xF) / 15.0)
            case 6: // RRGGBB
                return ParsedColor(
                    red: Double((intVal >> 16) & 0xFF) / 255.0,
                    green: Double((intVal >> 8) & 0xFF) / 255.0,
                    blue: Double(intVal & 0xFF) / 255.0,
                    alpha: 1.0)
            case 8: // RRGGBBAA
                return ParsedColor(
                    red: Double((intVal >> 24) & 0xFF) / 255.0,
                    green: Double((intVal >> 16) & 0xFF) / 255.0,
                    blue: Double((intVal >> 8) & 0xFF) / 255.0,
                    alpha: Double(intVal & 0xFF) / 255.0)
            default:
                return nil
            }
        }

        let lower = text.lowercased()
        // rgb(...) or rgba(...)
        if lower.hasPrefix("rgb(") || lower.hasPrefix("rgba(") {
            let inner = lower.replacingOccurrences(of: "rgba(", with: "")
                             .replacingOccurrences(of: "rgb(", with: "")
                             .replacingOccurrences(of: ")", with: "")
            let parts = splitComponents(inner)
            if parts.count >= 3, let r = Double(parts[0]),
               let g = Double(parts[1]), let b = Double(parts[2]) {
                let a = parts.count >= 4 ? (Double(parts[3]) ?? 1.0) : 1.0
                return ParsedColor(
                    red: max(0, min(255, r)) / 255.0,
                    green: max(0, min(255, g)) / 255.0,
                    blue: max(0, min(255, b)) / 255.0,
                    alpha: max(0, min(1.0, a)))
            }
        }

        // hsl(...) or hsla(...)
        if lower.hasPrefix("hsl(") || lower.hasPrefix("hsla(") {
            let inner = lower.replacingOccurrences(of: "hsla(", with: "")
                             .replacingOccurrences(of: "hsl(", with: "")
                             .replacingOccurrences(of: ")", with: "")
                             .replacingOccurrences(of: "%", with: "")
            let parts = splitComponents(inner)
            if parts.count >= 3, let h = Double(parts[0]),
               let s = Double(parts[1]), let l = Double(parts[2]) {
                let a = parts.count >= 4 ? (Double(parts[3]) ?? 1.0) : 1.0
                let rgb = hslToRgb(
                    hueDegrees: h,
                    saturationPercent: s,
                    lightnessPercent: l,
                    alpha: a)
                return ParsedColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: rgb.alpha)
            }
        }

        return nil
    }

    /// Standard CSS HSL → RGB conversion (Foley/van Dam). Inputs are clamped:
    /// hue wraps modulo 360, saturation/lightness clamp to percent ranges.
    static func hslToRgb(hueDegrees: Double, saturationPercent: Double,
                         lightnessPercent: Double, alpha: Double) -> ParsedColor {
        let h = (hueDegrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 360.0
        let s = max(0, min(100, saturationPercent)) / 100.0
        let l = max(0, min(100, lightnessPercent)) / 100.0

        let chroma = (1 - abs(2 * l - 1)) * s
        let hueSector = h * 6
        let secondary = chroma * (1 - abs(hueSector.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hueSector {
        case ..<1: (r1, g1, b1) = (chroma, secondary, 0)
        case ..<2: (r1, g1, b1) = (secondary, chroma, 0)
        case ..<3: (r1, g1, b1) = (0, chroma, secondary)
        case ..<4: (r1, g1, b1) = (0, secondary, chroma)
        case ..<5: (r1, g1, b1) = (secondary, 0, chroma)
        default:   (r1, g1, b1) = (chroma, 0, secondary)
        }
        let match = l - chroma / 2
        return ParsedColor(
            red: r1 + match,
            green: g1 + match,
            blue: b1 + match,
            alpha: max(0, min(1.0, alpha)))
    }

    private static func splitComponents(_ inner: String) -> [String] {
        inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public enum CaseConverter {
    public enum CaseStyle: String, CaseIterable, Identifiable, Sendable {
        case camelCase = "camelCase"
        case pascalCase = "PascalCase"
        case snakeCase = "snake_case"
        case kebabCase = "kebab-case"
        case constantCase = "CONSTANT_CASE"
        case uppercase = "UPPERCASE"
        case lowercase = "lowercase"
        case titleCase = "Title Case"

        public var id: String { rawValue }
    }

    public static func convert(_ text: String, to style: CaseStyle) -> String {
        let words = splitWords(text)
        guard !words.isEmpty else {
            switch style {
            case .uppercase: return text.uppercased()
            case .lowercase: return text.lowercased()
            default: return text
            }
        }

        switch style {
        case .camelCase:
            let first = words[0].lowercased()
            let rest = words.dropFirst().map { $0.capitalized }
            return ([first] + rest).joined()

        case .pascalCase:
            return words.map { $0.capitalized }.joined()

        case .snakeCase:
            return words.map { $0.lowercased() }.joined(separator: "_")

        case .kebabCase:
            return words.map { $0.lowercased() }.joined(separator: "-")

        case .constantCase:
            return words.map { $0.uppercased() }.joined(separator: "_")

        case .uppercase:
            return text.uppercased()

        case .lowercase:
            return text.lowercased()

        case .titleCase:
            return words.map { $0.capitalized }.joined(separator: " ")
        }
    }

    private static func splitWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }

        let chars = Array(text)
        for i in 0..<chars.count {
            let ch = chars[i]
            if ch.isLetter {
                if ch.isUppercase {
                    let prevIsLower = (i > 0 && chars[i-1].isLowercase)
                    let nextIsLower = (i + 1 < chars.count && chars[i+1].isLowercase && current.count > 1)
                    if prevIsLower || nextIsLower {
                        flush()
                    }
                }
                current.append(ch)
            } else if ch.isNumber {
                let prevIsLetter = (i > 0 && chars[i-1].isLetter)
                if prevIsLetter {
                    flush()
                }
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return words
    }
}

public enum TextTransformer {
    public static let maxTransformLength = 10_000

    public static func decodeBase64(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count <= maxTransformLength else { return nil }
        let pattern = "^[A-Za-z0-9+/]+={0,2}$"
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return nil }
        guard let data = Data(base64Encoded: trimmed),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty,
              decoded != trimmed,
              decoded.allSatisfy({ !$0.isASCII || $0.isWhitespace || $0.isLetter
                                   || $0.isNumber || $0.isPunctuation || $0.isSymbol }) else {
            return nil
        }
        return decoded
    }

    public static func encodeBase64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    public static func decodeURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("%"), trimmed.count <= maxTransformLength else { return nil }
        guard let decoded = trimmed.removingPercentEncoding, decoded != trimmed else { return nil }
        return decoded
    }

    public static func encodeURL(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }
}

/// Decoded JWT parts. Only the pre-rendered JSON strings are stored so the
/// struct stays Sendable.
public struct JWTData: Sendable, Equatable {
    public let headerJSON: String
    public let payloadJSON: String
    public let algorithm: String
    public let isExpired: Bool?
    public let expirationDate: Date?
    public let issuedAtDate: Date?
    public let subject: String?
    public let issuer: String?

    public static func parse(_ text: String?) -> JWTData? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20, trimmed.count <= 20_000 else { return nil }
        let parts = trimmed.components(separatedBy: ".")
        guard parts.count == 3 else { return nil }

        guard let headerObj = decodeBase64URLJSON(parts[0]),
              let payloadObj = decodeBase64URLJSON(parts[1]) else {
            return nil
        }

        let alg = (headerObj["alg"] as? String) ?? "Unknown"
        let typ = (headerObj["typ"] as? String)?.uppercased()
        guard headerObj["alg"] != nil || typ == "JWT" else {
            return nil
        }

        let headerStr = prettyJSON(headerObj)
        let payloadStr = prettyJSON(payloadObj)

        func epochDate(_ key: String) -> Date? {
            guard let value = payloadObj[key] else { return nil }
            let seconds: Double?
            if let num = value as? Double {
                seconds = num
            } else if let int = value as? Int64 {
                seconds = Double(int)
            } else if let int = value as? Int {
                seconds = Double(int)
            } else {
                seconds = nil
            }
            return seconds.map { Date(timeIntervalSince1970: $0) }
        }

        let expDate = epochDate("exp")

        return JWTData(
            headerJSON: headerStr,
            payloadJSON: payloadStr,
            algorithm: alg,
            isExpired: expDate.map { $0 < Date() },
            expirationDate: expDate,
            issuedAtDate: epochDate("iat"),
            subject: payloadObj["sub"] as? String,
            issuer: payloadObj["iss"] as? String
        )
    }

    private static func prettyJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func decodeBase64URLJSON(_ base64URL: String) -> [String: Any]? {
        var base64 = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any] else {
            return nil
        }
        return dict
    }
}

public struct EpochData: Sendable, Equatable {
    public let date: Date
    public let unitDescription: String
    public let localFormatted: String
    public let iso8601: String
    public let relativeFormatted: String
    public let unixSeconds: Int64
    public let unixMillis: Int64

    private static let localFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .long
        return df
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    public static func parse(_ text: String?) -> EpochData? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 9, trimmed.count <= 22 else { return nil }

        // Must be purely digits (or digits followed by decimal fractions)
        let parts = trimmed.components(separatedBy: ".")
        guard parts.count <= 2, parts[0].allSatisfy(\.isNumber) else { return nil }
        if parts.count == 2 {
            guard parts[1].allSatisfy(\.isNumber) else { return nil }
        }

        guard let rawDouble = Double(trimmed) else { return nil }

        let date: Date
        let unit: String

        // Seconds: 10 digits (2001 to 2049); then milli/micro/nano scales.
        if rawDouble >= 1_000_000_000 && rawDouble <= 2_500_000_000 {
            date = Date(timeIntervalSince1970: rawDouble)
            unit = "Seconds (10-digit)"
        } else if rawDouble >= 1_000_000_000_000 && rawDouble <= 2_500_000_000_000 {
            date = Date(timeIntervalSince1970: rawDouble / 1000.0)
            unit = "Milliseconds (13-digit)"
        } else if rawDouble >= 1_000_000_000_000_000 && rawDouble <= 2_500_000_000_000_000 {
            date = Date(timeIntervalSince1970: rawDouble / 1_000_000.0)
            unit = "Microseconds (16-digit)"
        } else if rawDouble >= 1_000_000_000_000_000_000 && rawDouble <= 2_500_000_000_000_000_000 {
            date = Date(timeIntervalSince1970: rawDouble / 1_000_000_000.0)
            unit = "Nanoseconds (19-digit)"
        } else {
            return nil
        }

        let now = Date()
        return EpochData(
            date: date,
            unitDescription: unit,
            localFormatted: localFormatter.string(from: date),
            iso8601: isoFormatter.string(from: date),
            relativeFormatted: relativeFormatter.localizedString(for: date, relativeTo: now),
            unixSeconds: Int64(date.timeIntervalSince1970),
            unixMillis: Int64(date.timeIntervalSince1970 * 1000)
        )
    }
}
