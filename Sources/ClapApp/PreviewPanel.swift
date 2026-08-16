import AppKit
import SwiftUI
import Combine
import ClapCore

/// Floating preview attached to the main panel (Maccy-style): shows the
/// selected entry's full content (scrollable text / scaled image) plus the
/// metadata the list can't fit — id, dates, use count, size, source app.
///
/// Never becomes key: the main panel hides on resignKey, so the preview must
/// be a passive child window.
final class ClapPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PreviewController {

    static let sideSize = NSSize(width: 360, height: 480)
    static let bandHeight: CGFloat = 300
    private static let gap: CGFloat = 8

    private let preview: ClapPreviewPanel
    private let appState: AppState
    private weak var parent: NSPanel?
    private var selectionCancellable: AnyCancellable?
    private var shownEntryKey: String?

    init(appState: AppState, parent: NSPanel) {
        self.appState = appState
        self.parent = parent
        preview = ClapPreviewPanel(
            contentRect: NSRect(origin: .zero, size: Self.sideSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        preview.isFloatingPanel = true
        preview.level = .floating
        preview.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        preview.isOpaque = false
        preview.backgroundColor = .clear
        preview.hasShadow = true
        preview.isReleasedWhenClosed = false
        preview.becomesKeyOnlyIfNeeded = true

        // Debounced: arrowing quickly through rows shouldn't churn previews.
        selectionCancellable = appState.$selectedID
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    /// Recomputes visibility, content, and placement for the current selection.
    func refresh() {
        guard let parent, parent.isVisible, let entry = appState.selectedEntry else {
            hide()
            return
        }
        let stateKey = "\(entry.id)-\(entry.isPinned)-\(entry.useCount)-\(entry.lastUsedAt.timeIntervalSince1970)"
        if shownEntryKey != stateKey || preview.contentView == nil {
            shownEntryKey = stateKey
            preview.contentView = NSHostingView(
                rootView: PreviewView(entry: entry).environmentObject(appState))
        }
        place(around: parent.frame, on: parent.screen ?? NSScreen.main)
        if preview.parent == nil {
            parent.addChildWindow(preview, ordered: .above)
        }
        preview.orderFront(nil)
    }

    func hide() {
        shownEntryKey = nil
        preview.parent?.removeChildWindow(preview)
        preview.orderOut(nil)
        preview.contentView = nil
    }

    /// Debug-only (see AppDelegate): renders the preview's view hierarchy to
    /// a PNG for headless UI verification.
    func writeSnapshot(to url: URL) {
        guard let view = preview.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Right of the panel, else left, else centered below, else centered
    /// above — first placement that fits the visible screen area wins.
    private func place(around panelFrame: NSRect, on screen: NSScreen?) {
        guard let visible = screen?.visibleFrame else { return }
        let side = NSSize(width: Self.sideSize.width, height: panelFrame.height)
        let band = NSSize(width: panelFrame.width, height: Self.bandHeight)

        var frame: NSRect
        if panelFrame.maxX + Self.gap + side.width <= visible.maxX {
            frame = NSRect(x: panelFrame.maxX + Self.gap, y: panelFrame.minY,
                           width: side.width, height: side.height)
        } else if panelFrame.minX - Self.gap - side.width >= visible.minX {
            frame = NSRect(x: panelFrame.minX - Self.gap - side.width, y: panelFrame.minY,
                           width: side.width, height: side.height)
        } else if panelFrame.minY - Self.gap - band.height >= visible.minY {
            frame = NSRect(x: panelFrame.minX, y: panelFrame.minY - Self.gap - band.height,
                           width: band.width, height: band.height)
        } else {
            frame = NSRect(x: panelFrame.minX, y: panelFrame.maxY + Self.gap,
                           width: band.width, height: min(band.height,
                                                          visible.maxY - panelFrame.maxY - Self.gap))
        }
        preview.setFrame(frame, display: true)
    }
}

// MARK: - SwiftUI content

struct PreviewView: View {
    @EnvironmentObject private var state: AppState
    let entry: ClipboardEntry

    @State private var image: NSImage?
    @State private var idCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            contentSection
            Divider()
            metadataSection
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var contentSection: some View {
        if entry.type == .text || entry.type == .shell {
            ScrollView([.vertical]) {
                Text(displayedText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        } else {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: entry.id) {
                let store = state.store
                let url = await store.imageFileURL(for: entry)
                image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                    guard let url else { return nil }
                    return NSImage(contentsOf: url)
                }.value
            }
        }
    }

    private var metadataSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                metaLabel("ID")
                HStack(spacing: 6) {
                    Text(String(entry.id))
                        .font(.system(size: 11, design: .monospaced))
                    Button {
                        copyID()
                    } label: {
                        Label(idCopied ? "Copied" : "Copy ID",
                              systemImage: idCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Copy the id for CLI use, e.g. clap get \(entry.id)")
                }
            }
            GridRow {
                metaLabel("Type")
                Text(entryTypeDescription)
                    .font(.system(size: 11))
            }
            GridRow {
                metaLabel("Size")
                Text(ByteSize.format(entry.sizeBytes)).font(.system(size: 11))
            }
            GridRow {
                metaLabel(entry.type == .shell ? "First run" : "First copied")
                Text(Self.dateFormatter.string(from: entry.createdAt)).font(.system(size: 11))
            }
            GridRow {
                metaLabel(entry.type == .shell ? "Last run" : "Last used")
                Text(Self.dateFormatter.string(from: entry.lastUsedAt)).font(.system(size: 11))
            }
            GridRow {
                metaLabel(entry.type == .shell ? "Times run" : "Times used")
                Text(String(entry.useCount)).font(.system(size: 11))
            }
            if let app = entry.sourceApp {
                GridRow {
                    metaLabel("From")
                    Text(Self.appDisplayName(bundleID: app))
                        .font(.system(size: 11))
                        .help(app)
                }
            }
            if entry.isPinned {
                GridRow {
                    metaLabel("Pinned")
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
        }
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
        return "\(prefix)\n\n⋯ [Preview truncated: showing first \(previewFormatted) of \(totalFormatted) characters. Copying or pasting will include the entire text.]"
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
            try? await Task.sleep(nanoseconds: 1_500_000_000)
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
