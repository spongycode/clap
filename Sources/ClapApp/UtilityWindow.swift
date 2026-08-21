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
            window.center()
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: rootView)
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
