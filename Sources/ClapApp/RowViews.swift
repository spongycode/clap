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
            }
            Text(preview)
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
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
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
        .id(entry.id)
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
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(4)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(4)
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
        .id(entry.id)
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
