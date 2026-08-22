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

    var hasCards: Bool {
        color != nil || base64Decoded != nil || urlDecoded != nil || jwt != nil || epoch != nil
    }

    static let empty = ParsedEntryContent()

    static func parse(_ content: String?) -> ParsedEntryContent {
        guard let content, !content.isEmpty, content.count <= 20_000 else { return .empty }
        return ParsedEntryContent(
            color: ColorParser.parse(content),
            base64Decoded: TextTransformer.decodeBase64(content),
            urlDecoded: TextTransformer.decodeURL(content),
            jwt: JWTData.parse(content),
            epoch: EpochData.parse(content)
        )
    }
}

struct PreviewView: View {
    @EnvironmentObject private var state: AppState
    let entry: ClipboardEntry

    @State private var image: NSImage?
    @State private var idCopied = false
    @State private var parsed: ParsedEntryContent = .empty

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            contentSection
            Divider()
            metadataSection
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: entry.id) {
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
                if parsed.hasCards {
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
            ImageContentView(entry: entry, image: image) { text in
                state.copyTransformedText(text)
            }
        }
    }

    // MARK: Metadata section

    private var metadataSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                metaLabel("Actions")
                HStack(spacing: 8) {
                    if entry.type == .image, let ocrText = entry.content, !ocrText.isEmpty {
                        Button {
                            state.copyTransformedText(ocrText)
                        } label: {
                            Label("Copy Text", systemImage: "doc.text.viewfinder")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Copy recognized OCR text from this image")
                    }
                    if entry.type == .text || entry.type == .shell,
                       let content = entry.content, content.count <= TextTransformer.maxTransformLength {
                        Menu {
                            TransformMenuContent(content: content) { transformed in
                                state.copyTransformedText(transformed)
                            }
                        } label: {
                            Label("Copy as…", systemImage: "textformat")
                                .font(.system(size: 11))
                        }
                        .menuStyle(.button)
                        .controlSize(.small)
                        .help("Convert text case or encode/decode and copy directly to clipboard")
                    }

                    if entry.type == .text || entry.type == .shell {
                        Button {
                            state.promptSetShortcut(entry)
                        } label: {
                            Label(entry.shortcut ?? "Shortcut",
                                  systemImage: entry.shortcut != nil ? "keyboard.fill" : "keyboard")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Assign or edit a text abbreviation (e.g. ;email) that auto-expands this snippet")
                    }

                    Button {
                        state.promptManageTags(entry)
                    } label: {
                        Label(entry.tags.isEmpty ? "Tags" : "\(entry.tags.count) Tags",
                              systemImage: entry.tags.isEmpty ? "tag" : "tag.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Manage tags and custom pinboards for this entry")

                    Button {
                        copyID()
                    } label: {
                        Label(idCopied ? "Copied" : "Copy ID",
                              systemImage: idCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy the numeric ID for CLI use, e.g. clap get \(entry.id)")
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
            if let app = entry.sourceApp {
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

    /// Copies the numeric id, marked transient so the pasteboard monitor
    /// doesn't record the id string as a new history entry.
    private func copyID() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(entry.id), forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        idCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Timing.copiedResetNanos)
            idCopied = false
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func appDisplayName(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}

// MARK: - Feature cards

private struct ColorCardView: View {
    let color: ParsedColor
    let source: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: color.red, green: color.green, blue: color.blue,
                            opacity: color.alpha))
                .frame(width: 46, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 2, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Color Preview")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(source.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(AppAlpha.Fill.subtle))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Color preview: \(source)")
    }
}

private struct DecodedCardView: View {
    let icon: String
    let tint: Color
    let title: String
    let decoded: String
    let onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button(action: onCopy) {
                        Label("Copy Decoded", systemImage: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Text(decoded)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.06))
        )
    }
}

private struct JWTCardView: View {
    @EnvironmentObject private var state: AppState
    let jwt: JWTData
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.indigo)
                Text("JWT Inspector")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.primary)

                Text(jwt.algorithm)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                    )

                if let isExp = jwt.isExpired {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(isExp ? Color.red : Color.green)
                            .frame(width: 6, height: 6)
                        Text(isExp ? "Expired" : "Valid")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isExp ? .red : .green)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill((isExp ? Color.red : Color.green).opacity(0.12))
                    )
                }

                Spacer()

                Menu {
                    Button("Copy Payload JSON") { onCopy(jwt.payloadJSON) }
                    Button("Copy Header JSON") { onCopy(jwt.headerJSON) }
                } label: {
                    Label("Copy JSON", systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if jwt.subject != nil || jwt.issuer != nil || jwt.expirationDate != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let sub = jwt.subject {
                        claimRow(label: "Subject:", value: sub, monospaced: true)
                    }
                    if let iss = jwt.issuer {
                        claimRow(label: "Issuer:", value: iss, monospaced: true)
                    }
                    if let expDate = jwt.expirationDate {
                        HStack(spacing: 6) {
                            Text("Expires:")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(Self.dateFormatter.string(from: expDate))
                                .font(.system(size: 11))
                        }
                    }
                }
            }

            Divider()

            Text("Decoded Payload:")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(jwt.payloadJSON)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(AppAlpha.Fill.subtle))
                )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.indigo.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.indigo.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private func claimRow(label: String, value: String, monospaced: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .lineLimit(1)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct EpochCardView: View {
    @EnvironmentObject private var state: AppState
    let epoch: EpochData
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "clock.badge.checkmark.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Epoch Timestamp")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.primary)

                    Text(epoch.unitDescription)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.12))
                        )
                }

                Spacer()

                Menu {
                    Button("Copy ISO 8601 (\(epoch.iso8601))") { onCopy(epoch.iso8601) }
                    Button("Copy Local Date") { onCopy(epoch.localFormatted) }
                    if epoch.unitDescription.contains("Seconds") {
                        Button("Copy as Milliseconds (\(epoch.unixMillis))") {
                            onCopy(String(epoch.unixMillis))
                        }
                    } else {
                        Button("Copy as Seconds (\(epoch.unixSeconds))") {
                            onCopy(String(epoch.unixSeconds))
                        }
                    }
                } label: {
                    Label("Copy Date", systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(epoch.localFormatted)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                HStack(spacing: 5) {
                    Text("UTC:")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(epoch.iso8601)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 5) {
                    Text("Relative:")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(epoch.relativeFormatted)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(AppAlpha.Fill.subtle))
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

private struct ImageContentView: View {
    let entry: ClipboardEntry
    let image: NSImage?
    let onCopyText: (String) -> Void

    var body: some View {
        ScrollView([.vertical]) {
            VStack(spacing: 12) {
                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(AppAlpha.Stroke.panelBorder), lineWidth: 0.5)
                            )
                    } else {
                        ProgressView()
                            .frame(height: 140)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Image preview, \(entry.imageFormat?.uppercased() ?? "unknown format")")
                .padding(.top, 4)

                if let ocrText = entry.content, !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Extracted Text (OCR)", systemImage: "doc.text.viewfinder")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Button { onCopyText(ocrText) } label: {
                                Label("Copy Text", systemImage: "doc.on.doc")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }

                        Text(ocrText)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(AppAlpha.Fill.subtle))
                            )
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                            )
                    )
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
