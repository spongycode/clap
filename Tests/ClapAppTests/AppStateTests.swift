import Testing
import Foundation
import AppKit
import ClapCore
@testable import ClapApp

/// Verifies the hover-selection gate: opening the panel under a stationary
/// cursor must not change the selection until the pointer moves, and the row
/// under the cursor is then selected with the tiniest movement.
@MainActor
@Suite("AppState hover gate & query building")
struct AppStateLogicTests {

    private func makeState() throws -> AppState {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clap-appstate-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ClipboardStore(dataDir: dir, now: { Date() })
        let monitor = PasteboardMonitor(store: store)
        return AppState(store: store, monitor: monitor)
    }

    @Test func hoverDoesNotStealSelectionWhileDisarmed() async throws {
        let state = try makeState()
        state.selectedID = 99
        state.hoverChanged(1, hovering: true)   // stationary cursor over row 1 on open
        #expect(state.selectedID == 99)
    }

    @Test func firstMovementSelectsRowUnderCursor() async throws {
        let state = try makeState()
        state.selectedID = 99
        state.hoverChanged(7, hovering: true)   // pointer parked over entry 7
        state.armPointer()                      // tiny physical movement
        #expect(state.selectedID == 7)
    }

    @Test func leavingTheListClearsPendingHover() async throws {
        let state = try makeState()
        state.hoverChanged(7, hovering: true)
        state.hoverChanged(7, hovering: false)  // pointer moved off the list before arming
        state.armPointer()
        #expect(state.selectedID == nil)
    }

    @Test func armedHoverSelectsImmediately() async throws {
        let state = try makeState()
        state.armPointer()
        state.hoverChanged(3, hovering: true)
        #expect(state.selectedID == 3)
        state.hoverChanged(4, hovering: true)
        #expect(state.selectedID == 4)
    }

    @Test func panelWillShowDisarmsAgain() async throws {
        let state = try makeState()
        state.armPointer()
        await state.panelWillShow()
        #expect(state.pointerArmed == false)
    }

    @Test func defaultQueryPerTab() {
        let classic = AppState.defaultQuery(tab: .classic, tag: nil, offset: 0)
        #expect(classic?.types == [.text, .image])

        let media = AppState.defaultQuery(tab: .media, tag: nil, offset: 40)
        #expect(media?.type == .image)
        #expect(media?.offset == 40)

        let shell = AppState.defaultQuery(tab: .shell, tag: nil, offset: 0)
        #expect(shell?.type == .shell)

        let favs = AppState.defaultQuery(tab: .favs, tag: nil, offset: 0)
        #expect(favs?.favoriteOnly == true)

        let tagged = AppState.defaultQuery(tab: .favs, tag: "work", offset: 0)
        #expect(tagged?.tag == "work")
    }
}

@Suite("Config defaults stay in sync with the app")
struct AppConfigDefaultsTests {
    @Test func storeHotkeyDefaultMatchesHotKeyPreset() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clap-defaults-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ClipboardStore(dataDir: dir)
        let stored = try await store.config(ConfigKey.uiHotkey)
        #expect(stored == HotKeyDefinition.defaultID)
    }
}

@MainActor
@Suite("Panel frame persistence")
struct PanelFrameTests {
    private let screen = NSRect(x: 0, y: 0, width: 1728, height: 1080)

    @Test func placementPrefersRightThenLeftThenLessOverflow() {
        let list = NSRect(x: 100, y: 200, width: 480, height: 500)
        #expect(SlideoutController.placement(listFrame: list, totalWidth: 840, screen: screen) == .right)

        let nearRight = NSRect(x: 1128, y: 200, width: 480, height: 500)
        #expect(SlideoutController.placement(listFrame: nearRight, totalWidth: 840, screen: screen) == .left)

        // Neither side fits on a narrow screen: pick the smaller overflow.
        let narrow = NSRect(x: 0, y: 0, width: 900, height: 800)
        // x=100: right overflows 40pt, left would overflow 260pt.
        let leftish = NSRect(x: 100, y: 100, width: 480, height: 500)
        #expect(SlideoutController.placement(listFrame: leftish, totalWidth: 840, screen: narrow) == .right)
        // x=300: right overflows 240pt, left only 60pt.
        let rightish = NSRect(x: 300, y: 100, width: 480, height: 500)
        #expect(SlideoutController.placement(listFrame: rightish, totalWidth: 840, screen: narrow) == .left)
    }

    @Test func clampPullsFrameFullyOnScreen() {
        let offRight = NSRect(x: 1600, y: -50, width: 480, height: 500)
        let clamped = PanelController.clamp(offRight, to: screen)
        #expect(clamped.maxX == screen.maxX)
        #expect(clamped.minY == screen.minY)
        #expect(clamped.size == offRight.size)

        let huge = NSRect(x: -10, y: -10, width: 5000, height: 5000)
        #expect(PanelController.clamp(huge, to: screen) == screen)

        let inside = NSRect(x: 100, y: 100, width: 480, height: 500)
        #expect(PanelController.clamp(inside, to: screen) == inside)
    }

    @Test func listFrameIgnoresPreviewOnEitherSide() {
        let slideout = SlideoutController()
        slideout.contentWidth = 480
        slideout.slideoutWidth = 360
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.setFrame(NSRect(x: 768, y: 200, width: 840, height: 500), display: false)

        slideout.state = .open
        slideout.placement = .left
        // Preview on the left: the list starts 360pt to the right.
        #expect(slideout.listFrame(of: window) == NSRect(x: 1128, y: 200, width: 480, height: 500))

        slideout.placement = .right
        #expect(slideout.listFrame(of: window) == NSRect(x: 768, y: 200, width: 480, height: 500))

        slideout.state = .closed
        window.setFrame(NSRect(x: 768, y: 200, width: 520, height: 500), display: false)
        #expect(slideout.listFrame(of: window) == NSRect(x: 768, y: 200, width: 520, height: 500))
    }
}
