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
