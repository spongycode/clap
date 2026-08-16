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
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                TextField(state.regexMode ? "Regex search…" : "Search…",
                          text: $state.rawQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($searchFocused)

                regexToggle

                Picker("", selection: $state.tab) {
                    Image(systemName: "doc.on.clipboard")
                        .tag(AppState.Tab.classic)
                    Image(systemName: "photo")
                        .tag(AppState.Tab.media)
                    Image(systemName: "terminal")
                        .tag(AppState.Tab.shell)
                    Image(systemName: "heart.fill")
                        .tag(AppState.Tab.favs)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 156)
                .help("⌘1 Classic · ⌘2 Media · ⌘3 Shell · ⌘4 Favs")

                Button {
                    state.onOpenSettings?()
                } label: {
                    Image(systemName: "gearshape")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
            if let error = state.searchError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Regex on/off toggle (also ⌘R). Styled like the ".*" button in editor
    /// search fields: tinted when active.
    private var regexToggle: some View {
        Button {
            state.regexMode.toggle()
        } label: {
            Text(".*")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(state.regexMode ? Color.white : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(state.regexMode ? Color.accentColor : Color.primary.opacity(0.08))
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
