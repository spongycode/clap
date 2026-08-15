import AppKit
import ClapCore

/// NSStatusItem with the clap menu. Recent entries and the pause state are
/// cached (refreshed on store/config change notifications and each open) so
/// menuNeedsUpdate can build the menu synchronously.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let store: ClipboardStore
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    var onOpenPanel: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private var cachedRecent: [ClipboardEntry] = []
    private var cachedPaused = false
    private var currentShortcut = HotKeyDefinition.presets[0]

    init(store: ClipboardStore, appState: AppState) {
        self.store = store
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let icon = Bundle.main.image(forResource: "MenuBarIcon")
            ?? Bundle.main.image(forResource: "MenuBarIcon@2x")
            ?? NSImage(contentsOfFile: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MenuBarIcon.png").path) {
            icon.isTemplate = true
            statusItem.button?.image = icon
        } else {
            statusItem.button?.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "clap"
            )
        }
        menu.delegate = self
        statusItem.menu = menu
        refreshCache()
    }

    func updateShortcut(_ definition: HotKeyDefinition) {
        currentShortcut = definition
        if menu.numberOfItems > 0 {
            rebuild()
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
        refreshCache() // freshen for the next open
    }

    /// Re-reads the top 5 text entries and the pause state.
    func refreshCache() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let recent = (try? await self.store.list(type: .text, limit: 5, offset: 0)) ?? []
            let paused = ((try? await self.store.config("monitoring.paused")) ?? "0") == "1"
            let hotkeyStr = ((try? await self.store.config("ui.hotkey")) ?? "cmd+shift+v")
            self.currentShortcut = HotKeyDefinition.find(hotkeyStr)
            self.cachedRecent = recent
            self.cachedPaused = paused
        }
    }

    // MARK: - Menu construction

    private func rebuild() {
        menu.removeAllItems()

        let open = NSMenuItem(
            title: "Open clap",
            action: #selector(openPanel),
            keyEquivalent: currentShortcut.menuKey
        )
        open.keyEquivalentModifierMask = currentShortcut.menuModifiers
        open.target = self
        menu.addItem(open)

        let pause = NSMenuItem(
            title: cachedPaused ? "Resume Monitoring" : "Pause Monitoring",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)

        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Recent")
        if cachedRecent.isEmpty {
            let empty = NSMenuItem(title: "No text entries", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for (index, entry) in cachedRecent.enumerated() {
                let item = NSMenuItem(
                    title: Self.preview(entry.content ?? ""),
                    action: #selector(copyRecent(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                submenu.addItem(item)
            }
        }
        recentItem.submenu = submenu
        menu.addItem(recentItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(
            title: "Quit clap",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
    }

    /// Single-line preview: control chars stripped, truncated to 40 chars.
    static func preview(_ text: String) -> String {
        let cleaned = text.prefix(200)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .components(separatedBy: .controlCharacters)
            .joined()
        if cleaned.count > 40 {
            return String(cleaned.prefix(40)) + "…"
        }
        return cleaned.isEmpty ? "(whitespace)" : cleaned
    }

    // MARK: - Actions

    @objc private func openPanel() {
        onOpenPanel?()
    }

    @objc private func togglePause() {
        let newPaused = !cachedPaused
        cachedPaused = newPaused
        Task { @MainActor [store] in
            try? await store.setConfig("monitoring.paused", value: newPaused ? "1" : "0")
            IPC.post(.configChanged)
        }
    }

    /// Copies via the same self-capture-aware path as the panel UI.
    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard cachedRecent.indices.contains(sender.tag) else { return }
        appState.copy(cachedRecent[sender.tag])
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }
}
