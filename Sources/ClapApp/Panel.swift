import AppKit
import SwiftUI

/// Borderless nonactivating floating panel hosting the SwiftUI UI.
final class ClapPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc via the responder chain.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// Owns the panel: shows it centered on the screen with the mouse, hides on
/// Esc / resignKey, and installs a local key monitor for all shortcuts.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {

    static let panelSize = NSSize(width: 780, height: 520)
    static let minPanelSize = NSSize(width: 520, height: 360)
    private static let frameConfigKey = "ui.panel_frame"

    private let panel: ClapPanel
    private let appState: AppState
    private var keyMonitor: Any?
    private var previewController: PreviewController?

    private var previousApp: NSRunningApplication?

    // Last user-chosen frame, cached so show() can restore it synchronously.
    // Persisted in the config table so it survives restarts.
    private var savedFrame: NSRect?
    private var suppressFrameSave = false
    private var frameSaveTask: Task<Void, Never>?

    init(appState: AppState) {
        self.appState = appState
        panel = ClapPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.minSize = Self.minPanelSize
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ContentView().environmentObject(appState))

        previewController = PreviewController(appState: appState, parent: panel)
        installKeyMonitor()

        // Warm the saved-frame cache before the first open.
        Task { [weak self] in
            guard let raw = try? await appState.store.config(Self.frameConfigKey) else { return }
            let rect = NSRectFromString(raw)
            if rect.width >= Self.minPanelSize.width, rect.height >= Self.minPanelSize.height {
                self?.savedFrame = rect
            }
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        appState.panelWillShow()
        suppressFrameSave = true
        if let saved = savedFrame, frameIsOnAVisibleScreen(saved) {
            // Reopen exactly where the user last dragged/resized it.
            panel.setFrame(saved, display: false)
        } else if let screen = screenWithMouse() {
            let frame = screen.visibleFrame
            let size = savedFrame?.size ?? Self.panelSize
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        suppressFrameSave = false
        panel.makeKeyAndOrderFront(nil)
        // Focus the search field once the panel is actually key.
        Task { @MainActor [appState] in
            appState.searchFocusToken += 1
        }
    }

    func hide(reactivatePreviousApp: Bool = false) {
        guard panel.isVisible else { return }
        previewController?.hide()
        panel.orderOut(nil)
        if reactivatePreviousApp {
            if let previousApp, !previousApp.isTerminated {
                previousApp.activate(options: .activateIgnoringOtherApps)
            } else {
                NSApp.hide(nil)
            }
        }
    }

    /// Debug-only (see AppDelegate): renders the panel's own view hierarchy
    /// to a PNG. Works headlessly — no screen-recording permission needed.
    func writeSnapshot(to url: URL) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Debug-only companion: snapshot of the preview window, if visible.
    func writePreviewSnapshot(to url: URL) {
        previewController?.writeSnapshot(to: url)
    }

    private func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// A frame counts as restorable when a meaningful part of it is on some
    /// screen (the saved display may have been unplugged).
    private func frameIsOnAVisibleScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let visible = screen.visibleFrame.intersection(frame)
            return visible.width >= 100 && visible.height >= 100
        }
    }

    private func rememberCurrentFrame() {
        guard !suppressFrameSave, panel.isVisible else { return }
        let frame = panel.frame
        savedFrame = frame
        // Debounced: windowDidMove fires continuously while dragging.
        frameSaveTask?.cancel()
        frameSaveTask = Task { [appState] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            try? await appState.store.setConfig(Self.frameConfigKey,
                                                value: NSStringFromRect(frame))
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    func windowDidMove(_ notification: Notification) {
        rememberCurrentFrame()
        // The preview may need to flip sides near a screen edge.
        previewController?.refresh()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberCurrentFrame()
        previewController?.refresh()
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKeyDown(event)
        }
    }

    /// True while the search field (its field editor) has keyboard focus.
    private var searchFieldIsFirstResponder: Bool {
        panel.firstResponder is NSText
    }

    /// Returns nil to swallow the event, or the event to let it through.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers ?? ""

        if modifiers == .command {
            switch chars {
            case "f":
                appState.searchFocusToken += 1
                return nil
            case "1":
                appState.tab = .classic
                return nil
            case "2":
                appState.tab = .media
                return nil
            case "3":
                appState.tab = .shell
                return nil
            case "4":
                appState.tab = .favs
                return nil
            case "p":
                appState.togglePinSelected()
                return nil
            case "s", "b":
                appState.toggleFavoriteSelected()
                return nil
            case "r":
                appState.regexMode.toggle()
                return nil
            case "d":
                appState.deleteSelected()
                return nil
            default:
                return event // e.g. Cmd+A/C/V handled by the Edit menu
            }
        }

        // Option+Delete removes the selected entry — unless the user is
        // mid-edit in the search field, where option+backspace must keep its
        // native "delete previous word" meaning.
        if modifiers == .option, event.keyCode == 51,
           !searchFieldIsFirstResponder || appState.rawQuery.isEmpty {
            appState.deleteSelected()
            return nil
        }

        guard modifiers.isEmpty else { return event }

        switch event.keyCode {
        case 53:  // esc
            hide()
            return nil
        case 126: // up arrow
            appState.moveSelection(-1)
            return nil
        case 125: // down arrow
            appState.moveSelection(1)
            return nil
        case 36, 76: // return / keypad enter
            appState.copySelected()
            return nil
        default:
            break
        }

        return event
    }
}
