import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox
import os.log

private let logger = Logger(subsystem: "com.spongycode.clap", category: "SnippetExpander")

/// Monitors system keystrokes at the HID driver level to detect registered snippet trigger shortcuts
/// (e.g. ";email", "!addr", ";zid") and automatically expands them into full text snippets.
public final class SnippetExpander: @unchecked Sendable {
    public static let shared = SnippetExpander()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var buffer = ""
    private let maxBufferLength = 40
    private var snippets: [String: String] = [:] // shortcut -> expansion
    private let lock = NSLock()
    private var isExpanding = false
    private var isEnabled = true
    private var retryTimer: Timer?

    private init() {}

    /// Updates the active shortcuts mapping.
    public func updateSnippets(_ newSnippets: [String: String]) {
        lock.lock()
        snippets = newSnippets
        lock.unlock()
    }

    /// Enables or disables snippet expansion.
    public func setEnabled(_ enabled: Bool) {
        lock.lock()
        isEnabled = enabled
        buffer.removeAll()
        lock.unlock()
    }

    /// Starts the global keystroke listener tap on the main runloop.
    public func start() {
        guard eventTap == nil else { return }

        guard AXIsProcessTrusted() else {
            Paster.promptAccessibility()
            if retryTimer == nil {
                DispatchQueue.main.async { [weak self] in
                    self?.retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                        if AXIsProcessTrusted() {
                            timer.invalidate()
                            self?.retryTimer = nil
                            self?.start()
                        }
                    }
                }
            }
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let expander = Unmanaged<SnippetExpander>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = expander.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            expander.handleEvent(event)
            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: selfPtr
        ) else {
            logger.warning("Could not create cghidEventTap for snippet expansion")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("SnippetExpander started listening for keyboard triggers")
    }

    /// Stops the global keystroke listener tap.
    public func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
            logger.info("SnippetExpander stopped")
        }
    }

    private func handleEvent(_ event: CGEvent) {
        lock.lock()
        defer { lock.unlock() }

        guard isEnabled, !isExpanding, !snippets.isEmpty else { return }

        // Use NSEvent translation to accurately preserve Shift characters (e.g. '!' vs '1') and keyboard layouts
        guard let nsEvent = NSEvent(cgEvent: event) else { return }

        let flags = nsEvent.modifierFlags
        if flags.contains(.command) || flags.contains(.control) {
            buffer.removeAll()
            return
        }

        let keyCode = nsEvent.keyCode

        // Reset buffer on navigation/terminator keys (Enter=36, Escape=53, Tab=48, Arrow keys: 123-126)
        if keyCode == 36 || keyCode == 53 || keyCode == 48 || (keyCode >= 123 && keyCode <= 126) {
            buffer.removeAll()
            return
        }

        // Handle backspace (KeyCode 51)
        if keyCode == 51 {
            if !buffer.isEmpty {
                buffer.removeLast()
            }
            return
        }

        guard let chars = nsEvent.characters, !chars.isEmpty else { return }

        buffer.append(chars)
        if buffer.count > maxBufferLength {
            buffer = String(buffer.suffix(maxBufferLength))
        }

        // Check if buffer ends with any registered shortcut
        for (shortcut, expansion) in snippets {
            guard !shortcut.isEmpty, buffer.hasSuffix(shortcut) else { continue }

            // Match detected!
            buffer.removeAll()
            isExpanding = true
            let shortcutLength = shortcut.count

            performExpansion(shortcutLength: shortcutLength, text: expansion)
            break
        }
    }

    private func performExpansion(shortcutLength: Int, text: String) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            // 1. Send `shortcutLength` backspaces with 3ms delay to cleanly erase the shortcut in the active app
            let src = CGEventSource(stateID: .hidSystemState)
            let vDel = CGKeyCode(kVK_Delete)
            for _ in 0..<shortcutLength {
                if let down = CGEvent(keyboardEventSource: src, virtualKey: vDel, keyDown: true),
                   let up = CGEvent(keyboardEventSource: src, virtualKey: vDel, keyDown: false) {
                    down.post(tap: .cghidEventTap)
                    usleep(3000)
                    up.post(tap: .cghidEventTap)
                    usleep(3000)
                }
            }

            // 2. Short pause for active app (Terminal, Chrome, etc.) to process backspaces
            usleep(25_000)

            // 3. Put expansion text into pasteboard and simulate Cmd+V paste
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)

                Paster.pasteToFrontmostApp()

                // 4. Cooldown before re-enabling
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.lock.lock()
                    self.isExpanding = false
                    self.lock.unlock()
                }
            }
        }
    }
}
