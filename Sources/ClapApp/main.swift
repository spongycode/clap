import AppKit

// AppDelegate-based entry point (no SwiftUI @main App) so we keep fine
// control over the nonactivating floating panel.
//
// Top-level code here is not implicitly MainActor-isolated, but this is the
// process entry point on the main thread, so assumeIsolated is correct.

// Strong reference: NSApplication.delegate is unowned.
let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
