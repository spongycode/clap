import AppKit
import ClapCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let logger = Logger(subsystem: "com.spongycode.clap", category: "app")

    private var store: ClipboardStore!
    private var monitor: PasteboardMonitor!
    private var shellMonitor: ShellHistoryMonitor!
    private var appState: AppState!
    private var panelController: PanelController!
    private var settingsController: SettingsWindowController!
    private var menuBar: MenuBarController!
    private var hotKey: HotKeyManager!
    private let workers = MaintenanceWorkers()
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store: ClipboardStore
        do {
            store = try ClipboardStore()
        } catch {
            logger.fault("unable to open clipboard store: \(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "clap could not open its database"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.store = store

        monitor = PasteboardMonitor(store: store)
        shellMonitor = ShellHistoryMonitor(store: store)
        appState = AppState(store: store, monitor: monitor)
        panelController = PanelController(appState: appState)
        settingsController = SettingsWindowController(store: store)
        menuBar = MenuBarController(store: store, appState: appState)

        appState.onCloseRequest = { [weak self] in self?.panelController.hide(reactivatePreviousApp: true) }
        appState.onOpenSettings = { [weak self] in self?.settingsController.show() }
        menuBar.onOpenPanel = { [weak self] in self?.panelController.show() }
        menuBar.onOpenSettings = { [weak self] in self?.settingsController.show() }

        hotKey = HotKeyManager()
        hotKey.onHotKey = { [weak self] in self?.panelController.toggle() }
        hotKey.register()

        installMainMenu()
        installDistributedObservers()

        Task { [monitor, shellMonitor] in
            await monitor?.refreshConfig()
            await monitor?.start()
            await shellMonitor?.start()
        }
        workers.start(store: store)

        logger.info("clap started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        workers.stop()
        Task { [shellMonitor] in
            await shellMonitor?.stop()
        }
        hotKey?.unregister()
        let center = DistributedNotificationCenter.default()
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: - Distributed notifications (IPC with the CLI)

    private func installDistributedObservers() {
        observers.append(IPC.observe(.openUI) { [weak self] in
            self?.panelController.show()
        })
        observers.append(IPC.observe(.storeChanged) { [weak self] in
            guard let self else { return }
            if self.panelController.isVisible {
                self.appState.reload()
            }
            self.menuBar.refreshCache()
        })
        observers.append(IPC.observe(.configChanged) { [weak self] in
            guard let self else { return }
            Task {
                await self.monitor.refreshConfig()
                await self.shellMonitor.refreshConfig()
            }
            self.menuBar.refreshCache()
        })

        // Debug builds only (also env-gated): shortly after launch, render the
        // panel's own view hierarchy to a PNG so headless test runs can verify
        // the UI without screen-recording permission. Compiled out of release
        // builds — an attacker-set env var must never be able to exfiltrate a
        // rendering of clipboard history.
        #if DEBUG
        if let snapshotDir = ProcessInfo.processInfo.environment["CLAP_DEBUG_SNAPSHOT_DIR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.panelController.show()
                if ProcessInfo.processInfo.environment["CLAP_DEBUG_SNAPSHOT_TAB"] == "media" {
                    self.appState.tab = .media
                }
                // Select the first row so the preview window appears too.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    self.appState.moveSelection(1)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    let dir = URL(fileURLWithPath: snapshotDir, isDirectory: true)
                    self.panelController.writeSnapshot(to: dir.appendingPathComponent("panel.png"))
                    self.panelController.writePreviewSnapshot(to: dir.appendingPathComponent("preview.png"))
                }
            }
        }
        #endif
    }

    // MARK: - Main menu

    /// Minimal main menu so standard Edit shortcuts (Cmd+C/V/X/A, undo)
    /// work inside the search field and the Settings window.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit clap",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}
