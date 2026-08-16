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
                Circle()
                    .fill(Color(nsColor: parsedColor))
                    .frame(width: 15, height: 15)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.20), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 0.5)
            }
            Text(highlightedPreview)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(entry.type == .shell ? .system(size: 13, design: .monospaced) : .system(size: 14))
            Spacer(minLength: 8)
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
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
            if (entry.type == .text || entry.type == .shell),
               let content = entry.content, content.count <= 10_000 {
                Menu("Copy As") {
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
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func string(for date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        return formatter.localizedString(for: date, relativeTo: Date())
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
