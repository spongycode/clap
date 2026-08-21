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
            leadingIcon
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
                TagPillView(tag: tag)
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
            Text(TextSummaries.relativeTime(entry.lastUsedAt, now: Date()))
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
            state.hoverChanged(entry.id, hovering: hovering)
        }
        .contextMenu { EntryContextMenu(entry: entry) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Copy clipboard entry: \(preview)")
        .accessibilityHint("Shows a context menu with more actions")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("entry-row.\(entry.id)")
        .onAppear { state.loadMoreIfNeeded(entry) }
        .id("\(entry.id)-\(entry.isPinned)-\(entry.isFavorite)")
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if entry.type == .image {
            ThumbnailView(entry: entry)
                .frame(width: 44, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if entry.type == .shell {
            Image(systemName: "terminal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
        } else if let parsed = ColorParser.parse(entry.content) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(red: parsed.red, green: parsed.green, blue: parsed.blue,
                            opacity: parsed.alpha))
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
            return TextSummaries.singleLine(entry.content ?? "", maxChars: 500)
        case .image:
            if let ocrText = entry.content, !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return TextSummaries.singleLine(ocrText, maxChars: 500)
            }
            let format = entry.imageFormat?.uppercased() ?? "IMAGE"
            return "\(format) image · \(ByteSize.format(entry.sizeBytes))"
        }
    }
}

// MARK: - Shared row context menu

struct EntryContextMenu: View {
    @EnvironmentObject private var state: AppState
    let entry: ClipboardEntry

    var body: some View {
        Button("Copy") { state.copy(entry) }
        Button(tagsTitle) {
            state.promptManageTags(entry)
        }
        if entry.type == .text || entry.type == .shell {
            Button(shortcutTitle) {
                state.promptSetShortcut(entry)
            }
        }
        if entry.type == .text || entry.type == .shell,
           let content = entry.content, content.count <= TextTransformer.maxTransformLength {
            Menu("Copy As") {
                TransformMenuContent(content: content) { transformed in
                    state.copyTransformedText(transformed)
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

    private var tagsTitle: String {
        entry.tags.isEmpty
            ? "Manage Tags…"
            : "Manage Tags (\(entry.tags.map { "#\($0)" }.joined(separator: ", ")))…"
    }

    private var shortcutTitle: String {
        entry.shortcut == nil
            ? "Set Snippet Shortcut…"
            : "Edit Snippet Shortcut (\(entry.shortcut ?? ""))…"
    }
}

// MARK: - Shared "Copy As" transform menu sections

/// Single source of truth for the transform actions offered on text content.
/// Embedded by the row context menu and the preview panel's metadata menu.
struct TransformMenuContent: View {
    let content: String
    let onCopy: (String) -> Void

    var body: some View {
        if let epoch = EpochData.parse(content) {
            Section("Timestamp") {
                Button("Copy ISO 8601 Date") { onCopy(epoch.iso8601) }
                Button("Copy Local Formatted Date") { onCopy(epoch.localFormatted) }
                if epoch.unitDescription.contains("Seconds") {
                    Button("Copy as Milliseconds (\(epoch.unixMillis))") {
                        onCopy(String(epoch.unixMillis))
                    }
                } else {
                    Button("Copy as Seconds (\(epoch.unixSeconds))") {
                        onCopy(String(epoch.unixSeconds))
                    }
                }
            }
        }
        if let jwt = JWTData.parse(content) {
            Section("JWT Token") {
                Button("Copy Payload JSON") { onCopy(jwt.payloadJSON) }
                Button("Copy Header JSON") { onCopy(jwt.headerJSON) }
            }
        }
        if content.count <= 1000 {
            Section("Text Case") {
                ForEach(CaseConverter.CaseStyle.allCases) { style in
                    Button(style.rawValue) {
                        onCopy(CaseConverter.convert(content, to: style))
                    }
                }
            }
        }
        Section("Encode / Decode") {
            Button("Base64 Encode") { onCopy(TextTransformer.encodeBase64(content)) }
            if let decoded = TextTransformer.decodeBase64(content) {
                Button("Base64 Decode") { onCopy(decoded) }
            }
            Button("URL Encode") { onCopy(TextTransformer.encodeURL(content)) }
            if let decoded = TextTransformer.decodeURL(content) {
                Button("URL Decode") { onCopy(decoded) }
            }
        }
    }
}

// MARK: - Tag pill

struct TagPillView: View {
    let tag: String

    var body: some View {
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
}

// MARK: - Search match highlighter

enum SearchHighlighter {
    static func highlight(text: String, query: String, isRegex: Bool) -> AttributedString {
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
                    attributed[attrRange].backgroundColor = Self.highlightColor
                    attributed[attrRange].foregroundColor = .black
                }
            }
        } else {
            let tokens = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            for token in tokens {
                var searchRange = text.startIndex..<text.endIndex
                while let matchRange = text.range(of: token, options: .caseInsensitive, range: searchRange) {
                    if let attrRange = Range(matchRange, in: attributed) {
                        attributed[attrRange].backgroundColor = Self.highlightColor
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

    static let highlightColor = Color(red: 1.0, green: 0.88, blue: 0.15)
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
            state.hoverChanged(entry.id, hovering: hovering)
        }
        .contextMenu {
            Button("Copy") { state.copy(entry) }
            Button(entry.isFavorite ? "Remove from Favs" : "Add to Favs") { state.toggleFavorite(entry) }
            Button(entry.isPinned ? "Unpin" : "Pin") { state.togglePin(entry) }
            Divider()
            Button("Delete", role: .destructive) { state.delete(entry) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Copy image entry, \(entry.imageFormat?.uppercased() ?? "image"), "
                            + ByteSize.format(entry.sizeBytes))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("media-cell.\(entry.id)")
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
                        Rectangle().fill(Color.primary.opacity(AppAlpha.Fill.soft))
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
