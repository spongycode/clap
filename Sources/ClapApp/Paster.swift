import AppKit
import Carbon.HIToolbox
import os

/// Synthesizes a Cmd+V keystroke into the frontmost app after clap writes to
/// the pasteboard (Maccy-style paste-on-select). The panel is nonactivating,
/// so the target app never lost key focus — the event lands where the user
/// was typing.
///
/// Posting keyboard events requires Accessibility permission. Without it this
/// degrades to copy-only: the first attempt shows the system prompt pointing
/// at System Settings → Privacy & Security → Accessibility.
enum Paster {
    private static let logger = Logger(subsystem: "com.spongycode.clap", category: "paste")

    /// True when the process is trusted for Accessibility. `prompt` shows the
    /// one-time system dialog when not yet trusted.
    @discardableResult
    static func ensureTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Posts Cmd+V to the session. Call after the pasteboard write, slightly
    /// delayed so the panel has closed and the write has settled.
    static func pasteToFrontmostApp() {
        guard ensureTrusted(prompt: true) else {
            logger.info("paste skipped: Accessibility permission not granted")
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        // Don't let our synthetic Cmd swallow or merge with keys the user is
        // physically holding right after pressing Enter.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            logger.error("paste failed: could not create keyboard events")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
