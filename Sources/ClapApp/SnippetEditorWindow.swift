import SwiftUI
import AppKit
import ClapCore

/// Manages the dedicated titled Snippet Abbreviation window.
@MainActor
final class SnippetWindowController: UtilityWindowController {
    static let shared = SnippetWindowController()

    private init() {
        super.init(title: "Snippet Abbreviation",
                   contentRect: NSRect(x: 0, y: 0, width: 440, height: 260))
    }

    func show(for entry: ClipboardEntry, state: AppState) {
        show(rootView: SnippetEditorView(entry: entry, onSave: { [weak self] shortcut in
            state.setShortcut(shortcut, for: entry)
            self?.close()
        }, onRemove: { [weak self] in
            state.setShortcut(nil, for: entry)
            self?.close()
        }, onCancel: { [weak self] in
            self?.close()
        }))
    }
}

struct SnippetEditorView: View {
    let entry: ClipboardEntry
    let onSave: (String?) -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Body Content
            VStack(alignment: .leading, spacing: 14) {
                Text("Type this abbreviation anywhere on your Mac to automatically expand this snippet:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Input Field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trigger Keyword:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    TextField("e.g. ;email, !zoom, or brb", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .focused($isFocused)
                        .onSubmit { save() }
                }

                // Expansion Preview
                if let content = entry.content {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Expands to:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text(content.prefix(180))
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(3)
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(AppAlpha.Fill.subtle))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(AppAlpha.Stroke.hairline), lineWidth: 0.5)
                                    )
                            )
                    }
                }
            }
            .padding(18)

            Spacer(minLength: 0)
            Divider()

            // Bottom Button Bar
            HStack {
                if entry.shortcut != nil {
                    Button("Remove Shortcut", role: .destructive) {
                        onRemove()
                    }
                }
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 440, height: 260)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            text = entry.shortcut ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFocused = true
            }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmed.isEmpty ? nil : trimmed)
    }
}
