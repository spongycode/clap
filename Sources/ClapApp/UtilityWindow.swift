import SwiftUI
import AppKit

/// Shared plumbing for the app's secondary titled windows (Settings, Snippet
/// Abbreviation, Manage Tags): lazy window creation, activation, key ordering.
@MainActor
class UtilityWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let title: String
    private let contentRect: NSRect
    private let styleMask: NSWindow.StyleMask

    init(title: String, contentRect: NSRect, styleMask: NSWindow.StyleMask = [.titled, .closable]) {
        self.title = title
        self.contentRect = contentRect
        self.styleMask = styleMask
        super.init()
    }

    func show(rootView: some View) {
        if window == nil {
            let window = NSWindow(
                contentRect: contentRect,
                styleMask: styleMask,
                backing: .buffered,
                defer: false
            )
            window.title = title
            window.isReleasedWhenClosed = false
            window.delegate = self
            // System Settings-style chrome: no visible titlebar strip; the
            // traffic lights float directly on the Liquid Glass and the
            // material runs edge to edge. Dragging works anywhere because
            // of isMovableByWindowBackground.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.center()
            self.window = window
        }
        // Esc closes the window (hidden cancel-action button).
        let chrome = rootView
            .background {
                Button("Close") { self.close() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        window?.contentView = NSHostingView(rootView: chrome)
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.window = nil
        }
    }
}
