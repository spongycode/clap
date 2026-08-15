import AppKit
import Carbon.HIToolbox

/// Preset hotkey options available in Settings and supported by Carbon RegisterEventHotKey.
struct HotKeyDefinition: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32
    let menuKey: String
    let menuModifiers: NSEvent.ModifierFlags

    static let presets: [HotKeyDefinition] = [
        HotKeyDefinition(
            id: "cmd+shift+v",
            title: "⌘ ⇧ V",
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(cmdKey | shiftKey),
            menuKey: "v",
            menuModifiers: [.command, .shift]
        ),
        HotKeyDefinition(
            id: "cmd+shift+b",
            title: "⌘ ⇧ B",
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(cmdKey | shiftKey),
            menuKey: "b",
            menuModifiers: [.command, .shift]
        ),
        HotKeyDefinition(
            id: "cmd+shift+c",
            title: "⌘ ⇧ C",
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(cmdKey | shiftKey),
            menuKey: "c",
            menuModifiers: [.command, .shift]
        ),
        HotKeyDefinition(
            id: "cmd+shift+space",
            title: "⌘ ⇧ Space",
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey),
            menuKey: " ",
            menuModifiers: [.command, .shift]
        ),
        HotKeyDefinition(
            id: "opt+space",
            title: "⌥ Space",
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey),
            menuKey: " ",
            menuModifiers: [.option]
        ),
        HotKeyDefinition(
            id: "ctrl+opt+v",
            title: "⌃ ⌥ V",
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(controlKey | optionKey),
            menuKey: "v",
            menuModifiers: [.control, .option]
        ),
        HotKeyDefinition(
            id: "ctrl+cmd+v",
            title: "⌃ ⌘ V",
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(controlKey | cmdKey),
            menuKey: "v",
            menuModifiers: [.control, .command]
        )
    ]

    static func find(_ id: String) -> HotKeyDefinition {
        presets.first(where: { $0.id == id }) ?? presets[0]
    }
}

/// Global hotkey manager via Carbon RegisterEventHotKey.
/// Configurable dynamically from user settings.
final class HotKeyManager {
    /// Invoked on the main actor when the hotkey fires.
    var onHotKey: (@MainActor () -> Void)?

    private var currentDefinition: HotKeyDefinition = HotKeyDefinition.presets[0]
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    static let signature: OSType = 0x434C_4150 // 'CLAP'

    func register(definition: HotKeyDefinition = HotKeyDefinition.presets[0]) {
        unregister()
        currentDefinition = definition
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            definition.keyCode,
            definition.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        _ = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard hotKeyID.signature == HotKeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.fire()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
    }

    private func fire() {
        Task { @MainActor [weak self] in
            self?.onHotKey?()
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    deinit {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
