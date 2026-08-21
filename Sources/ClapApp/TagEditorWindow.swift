import SwiftUI
import AppKit
import ClapCore

/// Manages the dedicated titled window for managing tags on an entry.
@MainActor
final class TagWindowController: UtilityWindowController {
    static let shared = TagWindowController()

    private init() {
        super.init(title: "Manage Tags & Pinboards",
                   contentRect: NSRect(x: 0, y: 0, width: 440, height: 320))
    }

    func show(for entry: ClipboardEntry, state: AppState) {
        let allTags = state.availableTags.map(\.tag)
        show(rootView: TagEditorView(
            entry: entry,
            suggestedTags: allTags,
            onSave: { [weak self] newTags in
                state.setTags(newTags, for: entry)
                self?.close()
            },
            onCancel: { [weak self] in
                self?.close()
            }
        ))
    }
}

struct TagEditorView: View {
    let entry: ClipboardEntry
    let suggestedTags: [String]
    let onSave: ([String]) -> Void
    let onCancel: () -> Void

    @State private var tags: [String] = []
    @State private var newTagText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Assign tags to organize this entry into custom pinboards:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Add Tag Field
                HStack(spacing: 8) {
                    TextField("Add a tag (e.g. work, code, sql, prompt)", text: $newTagText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .focused($isFocused)
                        .onSubmit {
                            addNewTag()
                        }

                    Button("Add") {
                        addNewTag()
                    }
                    .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // Current Active Tags
                VStack(alignment: .leading, spacing: 6) {
                    Text("Active Tags:")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if tags.isEmpty {
                        Text("No tags assigned yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(tags, id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        Text("#\(tag)")
                                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                        Button {
                                            tags.removeAll { $0 == tag }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        Capsule()
                                            .fill(Color.accentColor.opacity(0.15))
                                            .overlay(
                                                Capsule()
                                                    .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.5)
                                            )
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // Existing Suggestions
                let suggestions = suggestedTags.filter { !tags.contains($0) }
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Existing Pinboards:")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(suggestions, id: \.self) { suggestion in
                                    Button {
                                        tags.append(suggestion)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "plus")
                                                .font(.system(size: 9, weight: .bold))
                                            Text("#\(suggestion)")
                                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                        }
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule()
                                                .fill(Color.primary.opacity(AppAlpha.Fill.soft))
                                                .overlay(
                                                    Capsule()
                                                    .strokeBorder(Color.primary.opacity(AppAlpha.Stroke.panelBorder),
                                                                  lineWidth: 0.5)
                                                )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(18)

            Divider()

            // Action Buttons Bar
            HStack {
                if !tags.isEmpty {
                    Button("Clear Tags", role: .destructive) {
                        tags.removeAll()
                    }
                }
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave(tags)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 440)
        .onAppear {
            tags = entry.tags
            isFocused = true
        }
    }

    private func addNewTag() {
        let cleaned = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                                .lowercased()
        guard !cleaned.isEmpty else { return }
        if !tags.contains(cleaned) {
            tags.append(cleaned)
        }
        newTagText = ""
    }
}
