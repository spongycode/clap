import SwiftUI
import AppKit
import ClapCore

// MARK: - Classic list row

struct EntryRow: View {
    @EnvironmentObject private var state: AppState
    let entry: ClipboardEntry

    private var isSelected: Bool { state.selectedID == entry.id }

    var body: some View {
        HStack(spacing: 10) {
            if entry.type == .image {
                ThumbnailView(entry: entry)
                    .frame(width: 40, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if entry.type == .shell {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            } else if let parsedColor = ColorParser.parse(entry.content) {
                Circle()
                    .fill(Color(nsColor: parsedColor))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.20), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 0.5)
            }
            Text(highlightedPreview)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(entry.type == .shell ? .system(size: 12, design: .monospaced) : .system(size: 13))
            Spacer(minLength: 8)
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(RelativeTime.string(for: entry.lastUsedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
            Button(entry.isPinned ? "Unpin" : "Pin") { state.togglePin(entry) }
            Divider()
            Button("Delete", role: .destructive) { state.delete(entry) }
        }
        .onAppear { state.loadMoreIfNeeded(entry) }
        .id("\(entry.id)-\(entry.isPinned)")
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

            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(6)
            }

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
            Button(entry.isPinned ? "Unpin" : "Pin") { state.togglePin(entry) }
            Divider()
            Button("Delete", role: .destructive) { state.delete(entry) }
        }
        .onAppear { state.loadMoreIfNeeded(entry) }
        .id("\(entry.id)-\(entry.isPinned)")
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
