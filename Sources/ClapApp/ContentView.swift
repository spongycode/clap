import SwiftUI
import ClapCore

/// SwiftUI root hosted inside the floating panel.
struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var searchFocused: Bool
    @State private var lastEntry: ClipboardEntry?

    var body: some View {
        SlideoutView(controller: state.slideout) {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
        } slideout: {
            if let entry = state.selectedEntry ?? lastEntry {
                PreviewView(entry: entry)
            } else {
                EmptyView()
            }
        }
        .frame(minHeight: PanelController.minPanelSize.height,
               maxHeight: .infinity)
        .background(AdaptivePanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(AppAlpha.Stroke.panelBorder), lineWidth: 1)
        )
        .overlay(EdgeResizeOverlay())
        .onAppear { searchFocused = true }
        .onChange(of: state.searchFocusToken) { _, _ in searchFocused = true }
        .onChange(of: state.selectedEntry) { _, newEntry in
            if let newEntry {
                lastEntry = newEntry
            }
        }
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
                              text: Binding(
                                get: { state.rawQuery },
                                set: { state.queryChanged($0) }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($searchFocused)
                        .accessibilityIdentifier("search-field")

                    regexToggle
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(AppAlpha.Stroke.hairline), lineWidth: 0.5)
                        )
                )

                // 4 Wide Custom Segmented Tabs
                customTabBar

                // Settings Button (with circular hover highlight)
                SettingsButton {
                    state.onOpenSettings?()
                }
            }
            if state.tab == .favs {
                tagFilterBar
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
        .overlay(alignment: .bottom) {
            if let message = state.transientError {
                TransientErrorBanner(message: message)
            }
        }
    }

    private struct TransientErrorBanner: View {
        @EnvironmentObject private var state: AppState
        let message: String

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                Button {
                    state.dismissTransientError()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
            }
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.red.opacity(0.9)))
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("error-banner")
        }
    }

    /// Horizontal scrolling tag filter pills bar in the Favs / Pinboards tab
    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // "All" Pill
                tagPill(
                    title: "All",
                    count: state.selectedTag == nil ? (state.entries.count + state.pinned.count) : nil,
                    isSelected: state.selectedTag == nil
                ) {
                    state.selectTag(nil)
                }

                // Tag Pills
                ForEach(state.availableTags, id: \.tag) { item in
                    tagPill(
                        title: "#\(item.tag)",
                        count: item.count,
                        isSelected: state.selectedTag?.lowercased() == item.tag.lowercased()
                    ) {
                        state.selectTag(item.tag)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)
            .padding(.bottom, 2)
        }
    }

    private func tagPill(title: String, count: Int?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .bold : .medium,
                                  design: title.hasPrefix("#") ? .monospaced : .default))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.white.opacity(0.2) : Color.primary.opacity(AppAlpha.Fill.soft))
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(AppAlpha.Fill.soft))
            )
        }
        .buttonStyle(.plain)
    }

    /// Settings gear button with circular hover highlight
    private struct SettingsButton: View {
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(isHovered ? Color.primary.opacity(AppAlpha.Hover.fill) : Color.clear)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings-button")
        }
    }

    /// Custom segmented tabs with wide clickable hit targets
    private var customTabBar: some View {
        HStack(spacing: 2) {
            TabButton(icon: "doc.on.clipboard", tab: .classic, currentTab: state.tab, shortcut: "⌘1", label: "Classic") {
                state.selectTab(.classic)
            }
            TabButton(icon: "terminal", tab: .shell, currentTab: state.tab, shortcut: "⌘2", label: "Shell") {
                state.selectTab(.shell)
            }
            TabButton(icon: "heart.fill", tab: .favs, currentTab: state.tab, shortcut: "⌘3", label: "Favs") {
                state.selectTab(.favs)
            }
            TabButton(icon: "photo", tab: .media, currentTab: state.tab, shortcut: "⌘4", label: "Media") {
                state.selectTab(.media)
            }
        }
        .padding(2.5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(AppAlpha.Fill.soft))
        )
    }

    /// Individual tab item with full-area hit testing and distinct hover highlight
    private struct TabButton: View {
        let icon: String
        let tab: AppState.Tab
        let currentTab: AppState.Tab
        let shortcut: String
        let label: String
        let action: () -> Void

        @State private var isHovered = false

        private var isSelected: Bool {
            currentTab == tab
        }

        var body: some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: isSelected ? .bold : (isHovered ? .semibold : .medium)))
                    .foregroundStyle(
                        isSelected ? Color.white : (isHovered ? Color.primary : Color.secondary)
                    )
                    .frame(width: 50, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                isSelected ? Color.accentColor
                                    : (isHovered ? Color.primary.opacity(AppAlpha.Hover.fill) : Color.clear)
                            )
                            .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : Color.clear, radius: 2, y: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("\(label) (\(shortcut))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label) tab")
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            .accessibilityIdentifier("tab-\(tab.rawValue)")
        }
    }

    /// Regex on/off toggle with hover highlight and active state
    private var regexToggle: some View {
        RegexToggle(isOn: Binding(
            get: { state.regexMode },
            set: { state.setRegexMode($0) }
        ))
    }

    private struct RegexToggle: View {
        @Binding var isOn: Bool
        @State private var isHovered = false

        var body: some View {
            Button {
                isOn.toggle()
            } label: {
                Text(".*")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        isOn ? Color.green : (isHovered ? Color.primary : Color.secondary)
                    )
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                isOn
                                    ? Color.green.opacity(isHovered ? 0.24 : 0.16)
                                    : (isHovered
                                        ? Color.primary.opacity(AppAlpha.Hover.strongFill)
                                        : Color.primary.opacity(AppAlpha.Fill.soft))
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                isOn
                                    ? Color.green.opacity(isHovered ? 0.5 : 0.32)
                                    : (isHovered ? Color.primary.opacity(0.15) : Color.clear),
                                lineWidth: 0.5
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.borderless)
            .onHover { isHovered = $0 }
            .help(isOn ? "Regex search on (⌘R to turn off)"
                       : "Regex search off (⌘R to turn on)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Regex search mode")
            .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
            .accessibilityIdentifier("regex-toggle")
        }
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

    var body: some View {
        GeometryReader { geometry in
            let columnCount = max(2, Int(geometry.size.width / 160))
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 10),
                count: columnCount
            )
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
}
