import SwiftUI
import AppKit
import ClapCore

// MARK: - Classic list row

struct EntryRow: View {
    @EnvironmentObject private var state: AppState
    let entry: ClipboardEntry

    private var isSelected: Bool { state.selectedID == entry.id }

    var body: some View {
        HStack(spacing: 11) {
            if entry.type == .image {
                ThumbnailView(entry: entry)
                    .frame(width: 44, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if entry.type == .shell {
                Image(systemName: "terminal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            } else if let parsedColor = ColorParser.parse(entry.content) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: parsedColor))
                    .frame(width: 16, height: 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.20), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 0.5)
            } else if JWTData.parse(entry.content) != nil {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 18)
            } else if EpochData.parse(entry.content) != nil {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 18)
            }
            Text(highlightedPreview)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(entry.type == .shell ? .system(size: 13, design: .monospaced) : .system(size: 14))
            Spacer(minLength: 8)
            if let shortcut = entry.shortcut, !shortcut.isEmpty {
                Text(shortcut)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.purple.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.purple.opacity(0.25), lineWidth: 0.5)
                            )
                    )
            }
            ForEach(entry.tags.prefix(2), id: \.self) { tag in
                Text("#\(tag)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(Color.blue.opacity(0.10))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.blue.opacity(0.20), lineWidth: 0.5)
                            )
                    )
            }
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.orange)
            }
            if entry.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.red)
            }
            Text(RelativeTime.string(for: entry.lastUsedAt))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.36) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 0.5)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { state.copy(entry) }
        .onHover { hovering in
            if hovering { state.selectFromPointer(entry.id) }
        }
        .contextMenu {
            Button("Copy") { state.copy(entry) }
            Button(entry.tags.isEmpty ? "Manage Tags…" : "Manage Tags (\(entry.tags.map { "#\($0)" }.joined(separator: ", ")))…") {
                state.promptManageTags(entry)
            }
            if (entry.type == .text || entry.type == .shell) {
                Button(entry.shortcut == nil ? "Set Snippet Shortcut…" : "Edit Snippet Shortcut (\(entry.shortcut!))…") {
                    state.promptSetShortcut(entry)
                }
            }
            if (entry.type == .text || entry.type == .shell),
               let content = entry.content, content.count <= 10_000 {
                Menu("Copy As") {
                    if let epoch = EpochData.parse(content) {
                        Section("Timestamp") {
                            Button("Copy ISO 8601 Date") {
                                state.copyTransformedText(epoch.iso8601)
                            }
                            Button("Copy Local Formatted Date") {
                                state.copyTransformedText(epoch.localFormatted)
                            }
                            if epoch.unitDescription.contains("Seconds") {
                                Button("Copy as Milliseconds (\(epoch.unixMillis))") {
                                    state.copyTransformedText(String(epoch.unixMillis))
                                }
                            } else {
                                Button("Copy as Seconds (\(epoch.unixSeconds))") {
                                    state.copyTransformedText(String(epoch.unixSeconds))
                                }
                            }
                        }
                    }
                    if let jwt = JWTData.parse(content) {
                        Section("JWT Token") {
                            Button("Copy Payload JSON") {
                                state.copyTransformedText(jwt.payloadJSON)
                            }
                            Button("Copy Header JSON") {
                                state.copyTransformedText(jwt.headerJSON)
                            }
                        }
                    }
                    if content.count <= 1000 {
                        Section("Text Case") {
                            ForEach(CaseConverter.CaseStyle.allCases) { style in
                                Button(style.rawValue) {
                                    let converted = CaseConverter.convert(content, to: style)
                                    state.copyTransformedText(converted)
                                }
                            }
                        }
                    }
                    Section("Encode / Decode") {
                        Button("Base64 Encode") {
                            state.copyTransformedText(TextTransformer.encodeBase64(content))
                        }
                        if let decoded = TextTransformer.decodeBase64(content) {
                            Button("Base64 Decode") {
                                state.copyTransformedText(decoded)
                            }
                        }
                        Button("URL Encode") {
                            state.copyTransformedText(TextTransformer.encodeURL(content))
                        }
                        if let decoded = TextTransformer.decodeURL(content) {
                            Button("URL Decode") {
                                state.copyTransformedText(decoded)
                            }
                        }
                    }
                }
            }
            if entry.type == .image, let ocrText = entry.content, !ocrText.isEmpty {
                Button("Copy Extracted Text") { state.copyTransformedText(ocrText) }
            }
            Button(entry.isFavorite ? "Remove from Favs" : "Add to Favs") { state.toggleFavorite(entry) }
            Button(entry.isPinned ? "Unpin" : "Pin") { state.togglePin(entry) }
            Divider()
            Button("Delete", role: .destructive) { state.delete(entry) }
        }
        .onAppear { state.loadMoreIfNeeded(entry) }
        .id("\(entry.id)-\(entry.isPinned)-\(entry.isFavorite)")
    }

    private var highlightedPreview: AttributedString {
        SearchHighlighter.highlight(
            text: preview,
            query: state.trimmedQuery,
            isRegex: state.regexMode
        )
    }

    private var preview: String {
        switch entry.type {
        case .text, .shell:
            let content = entry.content ?? ""
            // Collapse whitespace/newlines into a single-line preview.
            return content.prefix(500)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .image:
            if let ocrText = entry.content, !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ocrText.prefix(500)
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            let format = entry.imageFormat?.uppercased() ?? "IMAGE"
            return "\(format) image · \(ByteSize.format(entry.sizeBytes))"
        }
    }
}

// MARK: - Color code parser

enum ColorParser {
    static func parse(_ raw: String?) -> NSColor? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4 && text.count <= 40 else { return nil }

        // Hex formats: #RGB, #RGBA, #RRGGBB, #RRGGBBAA, 0xRRGGBB
        if text.hasPrefix("#") || text.hasPrefix("0x") {
            let hex = text.hasPrefix("#") ? String(text.dropFirst()) : String(text.dropFirst(2))
            guard let intVal = UInt64(hex, radix: 16) else { return nil }
            switch hex.count {
            case 3: // RGB
                let r = CGFloat((intVal >> 8) & 0xF) / 15.0
                let g = CGFloat((intVal >> 4) & 0xF) / 15.0
                let b = CGFloat(intVal & 0xF) / 15.0
                return NSColor(red: r, green: g, blue: b, alpha: 1.0)
            case 4: // RGBA
                let r = CGFloat((intVal >> 12) & 0xF) / 15.0
                let g = CGFloat((intVal >> 8) & 0xF) / 15.0
                let b = CGFloat((intVal >> 4) & 0xF) / 15.0
                let a = CGFloat(intVal & 0xF) / 15.0
                return NSColor(red: r, green: g, blue: b, alpha: a)
            case 6: // RRGGBB
                let r = CGFloat((intVal >> 16) & 0xFF) / 255.0
                let g = CGFloat((intVal >> 8) & 0xFF) / 255.0
                let b = CGFloat(intVal & 0xFF) / 255.0
                return NSColor(red: r, green: g, blue: b, alpha: 1.0)
            case 8: // RRGGBBAA
                let r = CGFloat((intVal >> 24) & 0xFF) / 255.0
                let g = CGFloat((intVal >> 16) & 0xFF) / 255.0
                let b = CGFloat((intVal >> 8) & 0xFF) / 255.0
                let a = CGFloat(intVal & 0xFF) / 255.0
                return NSColor(red: r, green: g, blue: b, alpha: a)
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
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                             .map { $0.trimmingCharacters(in: .whitespaces) }
                             .filter { !$0.isEmpty }
            if parts.count >= 3 {
                guard let r = Double(parts[0]),
                      let g = Double(parts[1]),
                      let b = Double(parts[2]) else { return nil }
                let a = parts.count >= 4 ? (Double(parts[3]) ?? 1.0) : 1.0
                return NSColor(red: CGFloat(max(0, min(255, r)) / 255.0),
                               green: CGFloat(max(0, min(255, g)) / 255.0),
                               blue: CGFloat(max(0, min(255, b)) / 255.0),
                               alpha: CGFloat(max(0, min(1.0, a))))
            }
        }

        // hsl(...) or hsla(...)
        if lower.hasPrefix("hsl(") || lower.hasPrefix("hsla(") {
            let inner = lower.replacingOccurrences(of: "hsla(", with: "")
                             .replacingOccurrences(of: "hsl(", with: "")
                             .replacingOccurrences(of: ")", with: "")
                             .replacingOccurrences(of: "%", with: "")
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                             .map { $0.trimmingCharacters(in: .whitespaces) }
                             .filter { !$0.isEmpty }
            if parts.count >= 3 {
                guard let h = Double(parts[0]),
                      let s = Double(parts[1]),
                      let l = Double(parts[2]) else { return nil }
                let a = parts.count >= 4 ? (Double(parts[3]) ?? 1.0) : 1.0
                let hNorm = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360.0
                let sNorm = max(0, min(100, s)) / 100.0
                let lNorm = max(0, min(100, l)) / 100.0
                return NSColor(hue: CGFloat(hNorm), saturation: CGFloat(sNorm), brightness: CGFloat(lNorm), alpha: CGFloat(max(0, min(1.0, a))))
            }
        }

        return nil
    }
}

// MARK: - Text case converter

enum CaseConverter {
    enum CaseStyle: String, CaseIterable, Identifiable {
        case camelCase = "camelCase"
        case pascalCase = "PascalCase"
        case snakeCase = "snake_case"
        case kebabCase = "kebab-case"
        case constantCase = "CONSTANT_CASE"
        case uppercase = "UPPERCASE"
        case lowercase = "lowercase"
        case titleCase = "Title Case"

        var id: String { rawValue }
    }

    static func convert(_ text: String, to style: CaseStyle) -> String {
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

// MARK: - Text transformer (Base64 & URL encode/decode)

enum TextTransformer {
    static let maxTransformLength = 10_000

    static func decodeBase64(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count <= maxTransformLength else { return nil }
        let pattern = "^[A-Za-z0-9+/]+={0,2}$"
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return nil }
        guard let data = Data(base64Encoded: trimmed),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty,
              decoded != trimmed,
              decoded.allSatisfy({ !$0.isASCII || $0.isWhitespace || $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol }) else {
            return nil
        }
        return decoded
    }

    static func encodeBase64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    static func decodeURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("%"), trimmed.count <= maxTransformLength else { return nil }
        guard let decoded = trimmed.removingPercentEncoding, decoded != trimmed else { return nil }
        return decoded
    }

    static func encodeURL(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }
}

// MARK: - JWT Parser & Inspector

struct JWTData {
    let header: [String: Any]
    let payload: [String: Any]
    let headerJSON: String
    let payloadJSON: String
    let algorithm: String
    let isExpired: Bool?
    let expirationDate: Date?
    let issuedAtDate: Date?
    let subject: String?
    let issuer: String?

    static func parse(_ text: String?) -> JWTData? {
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

        let headerData = (try? JSONSerialization.data(withJSONObject: headerObj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let payloadData = (try? JSONSerialization.data(withJSONObject: payloadObj, options: [.prettyPrinted, .sortedKeys])) ?? Data()

        let headerStr = String(data: headerData, encoding: .utf8) ?? "{}"
        let payloadStr = String(data: payloadData, encoding: .utf8) ?? "{}"

        var expDate: Date? = nil
        var isExp: Bool? = nil
        if let expNum = payloadObj["exp"] as? Double {
            let date = Date(timeIntervalSince1970: expNum)
            expDate = date
            isExp = date < Date()
        } else if let expInt = payloadObj["exp"] as? Int64 {
            let date = Date(timeIntervalSince1970: Double(expInt))
            expDate = date
            isExp = date < Date()
        } else if let expInt = payloadObj["exp"] as? Int {
            let date = Date(timeIntervalSince1970: Double(expInt))
            expDate = date
            isExp = date < Date()
        }

        var iatDate: Date? = nil
        if let iatNum = payloadObj["iat"] as? Double {
            iatDate = Date(timeIntervalSince1970: iatNum)
        } else if let iatInt = payloadObj["iat"] as? Int64 {
            iatDate = Date(timeIntervalSince1970: Double(iatInt))
        } else if let iatInt = payloadObj["iat"] as? Int {
            iatDate = Date(timeIntervalSince1970: Double(iatInt))
        }

        return JWTData(
            header: headerObj,
            payload: payloadObj,
            headerJSON: headerStr,
            payloadJSON: payloadStr,
            algorithm: alg,
            isExpired: isExp,
            expirationDate: expDate,
            issuedAtDate: iatDate,
            subject: payloadObj["sub"] as? String,
            issuer: payloadObj["iss"] as? String
        )
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

// MARK: - Epoch & Timestamp Parser

struct EpochData {
    let date: Date
    let unitDescription: String
    let localFormatted: String
    let iso8601: String
    let relativeFormatted: String
    let unixSeconds: Int64
    let unixMillis: Int64

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

    static func parse(_ text: String?) -> EpochData? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 9, trimmed.count <= 22 else { return nil }

        // Must be purely digits (or digits followed by .0 or decimal fractions)
        let parts = trimmed.components(separatedBy: ".")
        guard parts.count <= 2, parts[0].allSatisfy(\.isNumber) else { return nil }
        if parts.count == 2 {
            guard parts[1].allSatisfy(\.isNumber) else { return nil }
        }

        guard let rawDouble = Double(trimmed) else { return nil }

        let date: Date
        let unit: String

        // Seconds: 1_000_000_000 ... 2_500_000_000 (10 digits: 2001 to 2049)
        if rawDouble >= 1_000_000_000 && rawDouble <= 2_500_000_000 {
            date = Date(timeIntervalSince1970: rawDouble)
            unit = "Seconds (10-digit)"
        }
        // Milliseconds: 1_000_000_000_000 ... 2_500_000_000_000 (13 digits)
        else if rawDouble >= 1_000_000_000_000 && rawDouble <= 2_500_000_000_000 {
            date = Date(timeIntervalSince1970: rawDouble / 1000.0)
            unit = "Milliseconds (13-digit)"
        }
        // Microseconds: 1_000_000_000_000_000 ... 2_500_000_000_000_000 (16 digits)
        else if rawDouble >= 1_000_000_000_000_000 && rawDouble <= 2_500_000_000_000_000 {
            date = Date(timeIntervalSince1970: rawDouble / 1_000_000.0)
            unit = "Microseconds (16-digit)"
        }
        // Nanoseconds: 1_000_000_000_000_000_000 ... 2_500_000_000_000_000_000 (19 digits)
        else if rawDouble >= 1_000_000_000_000_000_000 && rawDouble <= 2_500_000_000_000_000_000 {
            date = Date(timeIntervalSince1970: rawDouble / 1_000_000_000.0)
            unit = "Nanoseconds (19-digit)"
        } else {
            return nil
        }

        let seconds = Int64(date.timeIntervalSince1970)
        let millis = Int64(date.timeIntervalSince1970 * 1000)

        return EpochData(
            date: date,
            unitDescription: unit,
            localFormatted: localFormatter.string(from: date),
            iso8601: isoFormatter.string(from: date),
            relativeFormatted: relativeFormatter.localizedString(for: date, relativeTo: Date()),
            unixSeconds: seconds,
            unixMillis: millis
        )
    }
}

// MARK: - Search match highlighter

enum SearchHighlighter {
    static func highlight(
        text: String,
        query: String,
        isRegex: Bool,
        highlightColor: Color = Color(red: 1.0, green: 0.88, blue: 0.15)
    ) -> AttributedString {
        var attributed = AttributedString(text)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return attributed }

        if isRegex {
            guard let regex = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]) else {
                return attributed
            }
            let nsString = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                if let swiftRange = Range(match.range, in: text),
                   let attrRange = Range(swiftRange, in: attributed) {
                    attributed[attrRange].backgroundColor = highlightColor
                    attributed[attrRange].foregroundColor = .black
                }
            }
        } else {
            let tokens = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            for token in tokens {
                var searchRange = text.startIndex..<text.endIndex
                while let matchRange = text.range(of: token, options: .caseInsensitive, range: searchRange) {
                    if let attrRange = Range(matchRange, in: attributed) {
                        attributed[attrRange].backgroundColor = highlightColor
                        attributed[attrRange].foregroundColor = .black
                    }
                    if matchRange.upperBound < text.endIndex {
                        searchRange = matchRange.upperBound..<text.endIndex
                    } else {
                        break
                    }
                }
            }
        }

        return attributed
    }
}

// MARK: - Media grid cell

struct MediaCell: View {
    @EnvironmentObject private var state: AppState
    let entry: ClipboardEntry

    private var isSelected: Bool { state.selectedID == entry.id }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ThumbnailView(entry: entry)
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .clipped()

            HStack(spacing: 4) {
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(5)
                        .background(.ultraThinMaterial, in: Circle())
                }
                if entry.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(5)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(6)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 3.5) {
                        if let format = entry.imageFormat?.uppercased() {
                            Text(format)
                                .fontWeight(.bold)
                            Text("·")
                        }
                        Text(ByteSize.format(entry.sizeBytes))
                    }
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.65))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                            )
                    )
                    .padding(6)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { state.copy(entry) }
        .onHover { hovering in
            if hovering { state.selectFromPointer(entry.id) }
        }
        .contextMenu {
            Button("Copy") { state.copy(entry) }
            Button(entry.isFavorite ? "Remove from Favs" : "Add to Favs") { state.toggleFavorite(entry) }
            Button(entry.isPinned ? "Unpin" : "Pin") { state.togglePin(entry) }
            Divider()
            Button("Delete", role: .destructive) { state.delete(entry) }
        }
        .onAppear { state.loadMoreIfNeeded(entry) }
        .id("\(entry.id)-\(entry.isPinned)-\(entry.isFavorite)")
    }
}

// MARK: - Async thumbnail

struct ThumbnailView: View {
    @EnvironmentObject private var state: AppState
    let entry: ClipboardEntry
    @State private var image: NSImage?

    var body: some View {
        // Layout size comes from Color.clear (i.e. whatever frame the parent
        // proposes); the image is drawn as an overlay and clipped. A wide
        // landscape image can therefore never push the cell's layout and
        // overlap its neighbors — scaledToFill alone leaks its natural size.
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(Color.primary.opacity(0.06))
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipped()
            .task(id: entry.id) {
                image = await state.thumbnail(for: entry)
            }
    }
}

// MARK: - Helpers

enum RelativeTime {
    static func string(for date: Date) -> String {
        let interval = max(0, Date().timeIntervalSince(date))
        if interval < 60 { return "now" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 30 { return "\(days)d ago" }
        let months = days / 30
        if months < 12 { return "\(months)mo ago" }
        let years = days / 365
        return "\(years)y ago"
    }
}

/// Translucent panel background.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
