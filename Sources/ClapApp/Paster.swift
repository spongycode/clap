import AppKit
import Carbon.HIToolbox
import os

/// Synthesizes a Cmd+V keystroke into the frontmost app after clap writes to
/// the pasteboard (Maccy-style paste-on-select).
enum Paster {
    private static let logger = Logger(subsystem: "com.spongycode.clap", category: "paste")
    private static var lastPromptTime: Date?

    /// Returns true if Accessibility permission is granted.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user once to grant Accessibility in System Settings.
    @discardableResult
    static func promptAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Opens macOS System Settings directly to Privacy & Security -> Accessibility.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Posts Cmd+V to the frontmost application.
    static func pasteToFrontmostApp() {
        if !isTrusted {
            // Rate-limit the system prompt to at most once every 60 seconds
            let now = Date()
            if lastPromptTime == nil || now.timeIntervalSince(lastPromptTime!) > 60 {
                lastPromptTime = now
                promptAccessibility()
            }
            // Attempt AppleScript fallback so paste can still succeed
            pasteViaAppleScript()
            return
        }

        pasteViaCGEvent()
    }

    /// Posts synthetic Cmd+V using CGEvent.
    private static func pasteViaCGEvent() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey = CGKeyCode(kVK_ANSI_V) // 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            logger.error("paste failed: could not create CGEvent, trying AppleScript fallback")
            pasteViaAppleScript()
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Fallback using System Events AppleScript if CGEvent is blocked.
    private static func pasteViaAppleScript() {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = NSAppleScript(source: "tell application \"System Events\" to keystroke \"v\" using command down")
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            if let error {
                logger.info("AppleScript paste attempt finished with info: \(error, privacy: .public)")
            }
        }
    }
}
