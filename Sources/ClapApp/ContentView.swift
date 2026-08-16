import SwiftUI
import ClapCore

/// SwiftUI root hosted inside the floating panel.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // Flexible: tracks the window as the user resizes the panel.
        .frame(minWidth: PanelController.minPanelSize.width,
               maxWidth: .infinity,
               minHeight: PanelController.minPanelSize.height,
               maxHeight: .infinity)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .onAppear { searchFocused = true }
        .onChange(of: state.searchFocusToken) { _, _ in searchFocused = true }
    }

    // MARK: - Header (search + tabs + gear)

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // Search Input Capsule
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField(state.regexMode ? "Regex search…" : "Search…",
                              text: $state.rawQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($searchFocused)

                    regexToggle
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                )

                // 4 Wide Custom Segmented Tabs
                customTabBar

                // Settings Button
                Button {
                    state.onOpenSettings?()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            if let error = state.searchError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Custom segmented tabs with wide clickable hit targets
    private var customTabBar: some View {
        HStack(spacing: 2) {
            tabButton(icon: "doc.on.clipboard", tab: .classic, shortcut: "⌘1", label: "Classic")
            tabButton(icon: "photo", tab: .media, shortcut: "⌘2", label: "Media")
            tabButton(icon: "terminal", tab: .shell, shortcut: "⌘3", label: "Shell")
            tabButton(icon: "heart.fill", tab: .favs, shortcut: "⌘4", label: "Favs")
        }
        .padding(2.5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private func tabButton(icon: String, tab: AppState.Tab, shortcut: String, label: String) -> some View {
        Button {
            state.tab = tab
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: state.tab == tab ? .bold : .medium))
                .foregroundStyle(state.tab == tab ? Color.white : Color.secondary)
                .frame(width: 48, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(state.tab == tab ? Color.accentColor : Color.clear)
                        .shadow(color: state.tab == tab ? Color.accentColor.opacity(0.3) : Color.clear, radius: 2, y: 1)
                )
        }
        .buttonStyle(.plain)
        .help("\(label) (\(shortcut))")
    }

    /// Regex on/off toggle (also ⌘R). Styled like modern IDE search toggles
    /// with subtle tinted fill and matte green text.
    private var regexToggle: some View {
        Button {
            state.regexMode.toggle()
        } label: {
            Text(".*")
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundStyle(state.regexMode ? Color.green : Color.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(state.regexMode ? Color.green.opacity(0.16) : Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(state.regexMode ? Color.green.opacity(0.32) : Color.clear, lineWidth: 0.5)
                )
        }
        .buttonStyle(.borderless)
        .help(state.regexMode ? "Regex search on (⌘R to turn off)"
                              : "Regex search off (⌘R to turn on)")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if state.flatRows.isEmpty {
            EmptyStateView(hasQuery: !state.trimmedQuery.isEmpty, tab: state.tab)
        } else if state.tab == .media {
            MediaGridView()
        } else {
            ClassicListView()
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let hasQuery: Bool
    let tab: AppState.Tab

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var iconName: String {
        if hasQuery { return "magnifyingglass" }
        switch tab {
        case .classic: return "doc.on.clipboard"
        case .media: return "photo.on.rectangle.angled"
        case .shell: return "terminal"
        case .favs: return "star"
        }
    }

    private var emptyMessage: String {
        if hasQuery { return "No results" }
        switch tab {
        case .classic: return "No clipboard history yet"
        case .media: return "No image history yet"
        case .shell: return "No shell commands yet"
        case .favs: return "No pinned favorites yet (press ⌘P to pin)"
        }
    }
}

// MARK: - Classic tab

struct ClassicListView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if state.showsPinnedSection {
                        SectionHeaderView(title: "Pinned")
                        ForEach(state.pinned, id: \.id) { entry in
                            EntryRow(entry: entry)
                        }
                        SectionHeaderView(title: "Recent")
                    }
                    ForEach(state.entries, id: \.id) { entry in
                        EntryRow(entry: entry)
                    }
                }
                .padding(8)
            }
            .onChange(of: state.selectedID) { _, id in
                if let id, !state.selectionCameFromPointer { proxy.scrollTo(id) }
            }
        }
    }
}

struct SectionHeaderView: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

// MARK: - Media tab

struct MediaGridView: View {
    @EnvironmentObject private var state: AppState

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10),
        count: 4
    )

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(state.entries) { entry in
                        MediaCell(entry: entry)
                    }
                }
                .padding(12)
            }
            .onChange(of: state.selectedID) { _, id in
                if let id, !state.selectionCameFromPointer { proxy.scrollTo(id) }
            }
        }
    }
}
