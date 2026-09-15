import AppKit
import SwiftUI
import Combine
import ClapCore

/// High-performance scrollable text preview using AppKit's TextKit 2 layout manager.
/// Virtualizes long text (1,000+ chars up to megabytes) with native text selection.
struct LargeTextPreviewView: NSViewRepresentable {
    let text: String
    let query: String
    let isRegex: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastText: String?
        var lastQuery: String?
        var lastRegex: Bool?
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 14, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        context.coordinator.lastText = text
        context.coordinator.lastQuery = query
        context.coordinator.lastRegex = isRegex
        applyText(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coord = context.coordinator
        if coord.lastText == text && coord.lastQuery == query && coord.lastRegex == isRegex {
            return
        }
        coord.lastText = text
        coord.lastQuery = query
        coord.lastRegex = isRegex
        applyText(to: textView)
    }

    private func applyText(to textView: NSTextView) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            textView.string = text
            textView.textColor = .labelColor
            textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            return
        }

        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]

        let mutableAttr = NSMutableAttributedString(string: text, attributes: defaultAttributes)

        let highlightBg = NSColor(red: 1.0, green: 0.88, blue: 0.15, alpha: 1.0)
        let highlightFg = NSColor.black

        if isRegex {
            if let regex = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]) {
                let scanLength = min((text as NSString).length, 100_000)
                let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: scanLength))
                for match in matches {
                    mutableAttr.addAttributes([
                        .backgroundColor: highlightBg,
                        .foregroundColor: highlightFg
                    ], range: match.range)
                }
            }
        } else {
            let tokens = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            let nsString = text as NSString
            let scanLength = min(nsString.length, 100_000)
            for token in tokens {
                var searchRange = NSRange(location: 0, length: scanLength)
                while searchRange.location < scanLength {
                    let found = nsString.range(of: token, options: .caseInsensitive, range: searchRange)
                    if found.location != NSNotFound {
                        mutableAttr.addAttributes([
                            .backgroundColor: highlightBg,
                            .foregroundColor: highlightFg
                        ], range: found)
                        let nextLoc = found.location + found.length
                        if nextLoc >= scanLength { break }
                        searchRange = NSRange(location: nextLoc, length: scanLength - nextLoc)
                    } else {
                        break
                    }
                }
            }
        }

        textView.textStorage?.setAttributedString(mutableAttr)
    }
}

// MARK: - SwiftUI content

/// Smart-card payloads parsed once per entry instead of on every body
/// evaluation (JWT parsing alone runs JSONSerialization).
private struct ParsedEntryContent {
    var color: ParsedColor?
    var base64Decoded: String?
    var urlDecoded: String?
    var jwt: JWTData?
    var epoch: EpochData?
    var json: JSONData?
    /// Set when strict parse failed but JSONRepair recovered the document.
    var jsonRepair: JSONRepairResult?

    var hasCards: Bool {
        color != nil || base64Decoded != nil || urlDecoded != nil || jwt != nil
            || epoch != nil || json != nil || jsonRepair != nil
    }

    static let empty = ParsedEntryContent()

    static func parse(_ content: String?) -> ParsedEntryContent {
        guard let content, !content.isEmpty, content.count <= 20_000 else { return .empty }
        var result = ParsedEntryContent(
            color: ColorParser.parse(content),
            base64Decoded: TextTransformer.decodeBase64(content),
            urlDecoded: TextTransformer.decodeURL(content),
            jwt: JWTData.parse(content),
            epoch: EpochData.parse(content),
            json: JSONData.parse(content)
        )
        if result.json == nil {
            result.jsonRepair = JSONRepair.repair(content)
        } else if let repair = JSONRepair.repair(content), repair.repaired != content {
            // Newer macOS JSONSerialization accepts JSON5-ish input (trailing
            // commas etc.). Parse success alone doesn't mean strict JSON —
            // prefer the repaired card so sloppiness is still surfaced.
            result.jsonRepair = repair
        }
        return result
    }
}

struct PreviewView: View {
    @EnvironmentObject private var state: AppState
    let entry: ClipboardEntry

    @State private var image: NSImage?
    @State private var parsed: ParsedEntryContent = .empty
    @State private var qrVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            contentSection
            Divider()
            metadataSection
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: entry.id) {
            qrVisible = false
            parsed = await Task.detached(priority: .userInitiated) {
                ParsedEntryContent.parse(entry.content)
            }.value
            if entry.type == .image {
                image = await state.fullImage(for: entry)
            }
        }
    }

    // MARK: Content section

    @ViewBuilder
    private var contentSection: some View {
        if entry.type == .text || entry.type == .shell {
            VStack(alignment: .leading, spacing: 0) {
                // QR is user-requested (toggle), not content-detected — so it
                // must render even when no smart cards were detected.
                if parsed.hasCards || qrVisible {
                    VStack(alignment: .leading, spacing: 10) {
                        if let color = parsed.color {
                            ColorCardView(color: color, source: entry.content ?? "")
                        }
                        if let decoded = parsed.base64Decoded {
                            DecodedCardView(icon: "doc.text.magnifyingglass",
                                            tint: .blue,
                                            title: "Base64 Decoded",
                                            decoded: decoded) { state.copyTransformedText(decoded) }
                        }
                        if let decoded = parsed.urlDecoded {
                            DecodedCardView(icon: "link",
                                            tint: .teal,
                                            title: "URL Decoded",
                                            decoded: decoded) { state.copyTransformedText(decoded) }
                        }
                        if let jwt = parsed.jwt {
                            JWTCardView(jwt: jwt) { text in state.copyTransformedText(text) }
                        }
                        if let epoch = parsed.epoch {
                            EpochCardView(epoch: epoch) { text in state.copyTransformedText(text) }
                        }
                        if qrVisible, let content = entry.content,
                           QRCodeBuilder.canEncode(content) {
                            QRCardView(content: content) { png in
                                state.copyGeneratedImage(png)
                            }
                        }
                        if let repair = parsed.jsonRepair,
                           let repaired = JSONData.parse(repair.repaired) {
                            JSONCardView(json: repaired,
                                         repairedFixes: repair.fixes) { text in
                                state.copyTransformedText(text)
                            }
                        } else if let json = parsed.json {
                            JSONCardView(json: json) { text in
                                state.copyTransformedText(text)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                }

                if let content = entry.content {
                    if content.count >= 1_000 {
                        LargeTextPreviewView(text: content,
                                             query: state.trimmedQuery,
                                             isRegex: state.regexMode)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView([.vertical]) {
                            Text(highlightedDisplayedText)
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }
        } else {
            ImageContentView(entry: entry, image: image,
                             showsQR: qrVisible,
                             onCopyImage: { state.copyGeneratedImage($0) },
                             onCopyText: { state.copyTransformedText($0) })
        }
    }

    // MARK: Metadata section

    private var metadataSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                metaLabel("Actions")
                HStack(spacing: 6) {
                    if entry.type == .image, let ocrText = entry.content, !ocrText.isEmpty {
                        IconActionButton(systemImage: "doc.text.viewfinder",
                                         help: "Copy extracted text (OCR)") {
                            state.copyTransformedText(ocrText)
                        }
                    }

                    if entry.type == .text || entry.type == .shell,
                       let content = entry.content,
                       content.count <= TextTransformer.maxTransformLength {
                        IconMenu(systemImage: "textformat") {
                            ForEach(CaseConverter.CaseStyle.allCases) { style in
                                Button(style.rawValue) {
                                    state.copyTransformedText(
                                        CaseConverter.convert(content, to: style))
                                }
                            }
                        }
                        .help("Copy as… camelCase, snake_case, kebab-case, UPPER, lower…")
                        .accessibilityLabel("Copy as different text case")

                        IconMenu(systemImage: "chevron.left.forwardslash.chevron.right") {
                            Button("Base64 Encode") {
                                state.copyTransformedText(TextTransformer.encodeBase64(content))
                            }
                            if let decoded = TextTransformer.decodeBase64(content) {
                                Button("Base64 Decode") {
                                    state.copyTransformedText(decoded)
                                }
                            }
                            Divider()
                            Button("URL Encode") {
                                state.copyTransformedText(TextTransformer.encodeURL(content))
                            }
                            if let decoded = TextTransformer.decodeURL(content) {
                                Button("URL Decode") {
                                    state.copyTransformedText(decoded)
                                }
                            }
                        }
                        .help("Copy Base64- or URL-encoded / decoded text")
                        .accessibilityLabel("Copy encoded or decoded text")
                    }

                    if let qrContent = entry.content, QRCodeBuilder.canEncode(qrContent) {
                        IconActionButton(systemImage: "qrcode",
                                         help: qrVisible ? "Hide QR code" : "Show QR code",
                                         isSelected: qrVisible) {
                            qrVisible.toggle()
                        }
                    }

                    if entry.type == .text || entry.type == .shell {
                        IconActionButton(systemImage: entry.shortcut != nil ? "bolt.fill" : "bolt",
                                         help: entry.shortcut != nil
                                             ? "Snippet shortcut: \(entry.shortcut ?? "")"
                                             : "Assign a snippet abbreviation (e.g. ;email)") {
                            state.promptSetShortcut(entry)
                        }
                    }

                    IconActionButton(systemImage: entry.tags.isEmpty ? "tag" : "tag.fill",
                                     help: entry.tags.isEmpty
                                         ? "Add tags"
                                         : "Tags: \(entry.tags.joined(separator: ", "))") {
                        state.promptManageTags(entry)
                    }
                }
            }
            GridRow {
                metaLabel("Type")
                Text(entryTypeDescription)
                    .font(.system(size: 12))
            }
            if entry.type == .image, let image {
                let rep = image.representations.first
                let w = rep?.pixelsWide ?? Int(image.size.width)
                let h = rep?.pixelsHigh ?? Int(image.size.height)
                GridRow {
                    metaLabel("Dimensions")
                    Text("\(w) × \(h) px")
                        .font(.system(size: 12))
                        .monospacedDigit()
                }
            }
            GridRow {
                metaLabel("Size")
                Text(ByteSize.format(entry.sizeBytes)).font(.system(size: 12))
            }
            GridRow {
                metaLabel(entry.type == .shell ? "First run" : "First copied")
                Text(Self.dateFormatter.string(from: entry.createdAt)).font(.system(size: 12))
            }
            GridRow {
                metaLabel(entry.type == .shell ? "Last run" : "Last used")
                Text(Self.dateFormatter.string(from: entry.lastUsedAt)).font(.system(size: 12))
            }
            GridRow {
                metaLabel(entry.type == .shell ? "Times run" : "Times used")
                Text(String(entry.useCount)).font(.system(size: 12))
            }
            if entry.type == .shell {
                GridRow {
                    metaLabel("From")
                    HStack(spacing: 6) {
                        // Shell rows have no source bundle id; Terminal.app's
                        // icon is the honest stand-in.
                        AppIconView(bundleID: "com.apple.Terminal", size: 14)
                        Text(Self.shellSourceName(entry.sourceApp))
                            .font(.system(size: 12))
                            .help(entry.sourceApp ?? "shell")
                    }
                }
            } else if let app = entry.sourceApp {
                GridRow {
                    metaLabel("From")
                    HStack(spacing: 6) {
                        AppIconView(bundleID: app, size: 14)
                        Text(Self.appDisplayName(bundleID: app))
                            .font(.system(size: 12))
                            .help(app)
                    }
                }
            }
            if !entry.tags.isEmpty {
                GridRow(alignment: .top) {
                    metaLabel("Tags")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(entry.tags, id: \.self) { tag in
                                TagPillView(tag: tag)
                            }
                        }
                    }
                }
            }
            if entry.isPinned {
                GridRow {
                    metaLabel("Pinned")
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            if entry.isFavorite {
                GridRow {
                    metaLabel("Favorite")
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: Helpers

    private var highlightedDisplayedText: AttributedString {
        SearchHighlighter.highlight(
            text: displayedText,
            query: state.trimmedQuery,
            isRegex: state.regexMode
        )
    }

    private var displayedText: String {
        guard let content = entry.content else { return "" }
        let maxPreviewChars = 15_000
        if content.count <= maxPreviewChars {
            return content
        }
        let prefix = content.prefix(maxPreviewChars)
        let totalFormatted = NumberFormatter.localizedString(from: NSNumber(value: content.count), number: .decimal)
        let previewFormatted = NumberFormatter.localizedString(from: NSNumber(value: maxPreviewChars), number: .decimal)
        return "\(prefix)\n\n⋯ [Preview truncated: showing first \(previewFormatted) of \(totalFormatted) characters. "
            + "Copying or pasting will include the entire text.]"
    }

    private var entryTypeDescription: String {
        switch entry.type {
        case .text: return "Text"
        case .shell: return "Shell command"
        case .image: return "Image (\(entry.imageFormat?.uppercased() ?? "?"))"
        }
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// ".zsh_history" -> "zsh history"; empty/unknown -> "Terminal".
    static func shellSourceName(_ rawSource: String?) -> String {
        var name = (rawSource ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix(".") { name.removeFirst() }
        if name.hasSuffix("_history") { name.removeLast("_history".count) }
        return name.isEmpty ? "Terminal" : "\(name) history"
    }

    static func appDisplayName(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        // Prefer the bundle's localized display name; the on-disk name
        // carries a ".app" suffix nobody wants in the UI.
        if let bundle = Bundle(url: url) {
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
                return displayName
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
                return name
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Actions-row icon buttons

/// Circular hover-highlighting icon button used across the Actions row.
private struct IconActionButton: View {
    let systemImage: String
    let help: String
    var isSelected: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isSelected || isHovered ? Color.primary : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(isSelected || isHovered
                              ? Color.primary.opacity(AppAlpha.Hover.fill)
                              : Color.clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Dropdown variant of `IconActionButton`. Hover must be tracked on the
/// Menu itself — SwiftUI never delivers onHover to a Menu's label content.
private struct IconMenu<MenuItems: View>: View {
    let systemImage: String
    @ViewBuilder var items: () -> MenuItems

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
