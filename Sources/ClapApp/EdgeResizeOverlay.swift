import SwiftUI
import AppKit

// MARK: - Manual window edge/corner resize handles
//
// Native titled-window resize zones proved unreliable on this nonactivating
// panel, so we provide explicit 9pt strips + 20pt corner pads. Each handle
// drives the window frame directly during drag; min size and column widths are enforced.

enum ResizeDirection {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var cursor: NSCursor {
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return .closedHand
        case .topRight, .bottomLeft: return .closedHand
        }
    }
}

private final class ResizerView: NSView {
    let direction: ResizeDirection
    var slideoutController: SlideoutController?
    private var initialMouseLocation: NSPoint?
    private var initialWindowFrame: NSRect?
    private var initialContentWidth: CGFloat = 480
    private var initialSlideoutWidth: CGFloat = 360
    private var trackingArea: NSTrackingArea?

    init(direction: ResizeDirection, slideoutController: SlideoutController?) {
        self.direction = direction
        self.slideoutController = slideoutController
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        window?.isMovableByWindowBackground = false
    }

    override func mouseExited(with event: NSEvent) {
        if initialMouseLocation == nil {
            window?.isMovableByWindowBackground = true
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        direction.cursor.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: direction.cursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.isMovableByWindowBackground = false
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowFrame = window.frame
        if let slideout = slideoutController {
            initialContentWidth = slideout.contentWidth
            initialSlideoutWidth = slideout.slideoutWidth
        }
    }

    override func mouseUp(with event: NSEvent) {
        window?.isMovableByWindowBackground = true
        initialMouseLocation = nil
        initialWindowFrame = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let startMouse = initialMouseLocation,
              let startFrame = initialWindowFrame else { return }

        let currentMouse = NSEvent.mouseLocation
        let totalDx = currentMouse.x - startMouse.x
        let totalDy = currentMouse.y - startMouse.y

        let screenFrame = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 3840, height: 2160)
        let maxW = max(PanelController.minPanelSize.width, screenFrame.width - 20)
        let maxH = max(PanelController.minPanelSize.height, screenFrame.height - 20)

        var newOrigin = startFrame.origin
        var newSize = startFrame.size

        let isOpen = slideoutController?.state.isOpen ?? false
        let isLeftPlacement = (slideoutController?.placement == .left)

        // 1. Horizontal Calculation
        switch direction {
        case .left, .topLeft, .bottomLeft:
            if let slideout = slideoutController {
                if isOpen {
                    if isLeftPlacement {
                        // Left edge is Preview
                        let newPrevW = max(slideout.minimumSlideoutWidth, initialSlideoutWidth - totalDx)
                        let clampedPrevW = min(maxW - initialContentWidth, newPrevW)
                        let totalW = clampedPrevW + initialContentWidth
                        slideout.slideoutWidth = clampedPrevW
                        newSize.width = totalW
                        newOrigin.x = startFrame.maxX - totalW
                    } else {
                        // Left edge is List
                        let newContW = max(slideout.minimumContentWidth, initialContentWidth - totalDx)
                        let clampedContW = min(maxW - initialSlideoutWidth, newContW)
                        let totalW = clampedContW + initialSlideoutWidth
                        slideout.contentWidth = clampedContW
                        newSize.width = totalW
                        newOrigin.x = startFrame.maxX - totalW
                    }
                } else {
                    let newContW = max(slideout.minimumContentWidth, initialContentWidth - totalDx)
                    let clampedContW = min(maxW, newContW)
                    slideout.contentWidth = clampedContW
                    newSize.width = clampedContW
                    newOrigin.x = startFrame.maxX - clampedContW
                }
            }

        case .right, .topRight, .bottomRight:
            if let slideout = slideoutController {
                if isOpen {
                    if isLeftPlacement {
                        // Right edge is List
                        let newContW = max(slideout.minimumContentWidth, initialContentWidth + totalDx)
                        let clampedContW = min(maxW - initialSlideoutWidth, newContW)
                        let totalW = clampedContW + initialSlideoutWidth
                        slideout.contentWidth = clampedContW
                        newSize.width = totalW
                    } else {
                        // Right edge is Preview
                        let newPrevW = max(slideout.minimumSlideoutWidth, initialSlideoutWidth + totalDx)
                        let clampedPrevW = min(maxW - initialContentWidth, newPrevW)
                        let totalW = initialContentWidth + clampedPrevW
                        slideout.slideoutWidth = clampedPrevW
                        newSize.width = totalW
                    }
                } else {
                    let newContW = max(slideout.minimumContentWidth, initialContentWidth + totalDx)
                    let clampedContW = min(maxW, newContW)
                    slideout.contentWidth = clampedContW
                    newSize.width = clampedContW
                }
            }

        default:
            break
        }

        // 2. Vertical Calculation (Cocoa screen coordinates: +Y is UP)
        switch direction {
        case .top, .topLeft, .topRight:
            let desiredHeight = startFrame.height + totalDy
            newSize.height = min(maxH, max(PanelController.minPanelSize.height, desiredHeight))
        case .bottom, .bottomLeft, .bottomRight:
            let desiredHeight = startFrame.height - totalDy
            let clampedHeight = min(maxH, max(PanelController.minPanelSize.height, desiredHeight))
            newSize.height = clampedHeight
            newOrigin.y = startFrame.maxY - clampedHeight
        default:
            break
        }

        window.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
    }
}

private struct ResizerHandle: NSViewRepresentable {
    let direction: ResizeDirection
    let slideoutController: SlideoutController?

    func makeNSView(context: Context) -> NSView {
        let view = ResizerView(direction: direction, slideoutController: slideoutController)
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let resizer = nsView as? ResizerView {
            resizer.slideoutController = slideoutController
        }
    }
}

/// Perimeter resize affordances: 9pt edge strips + 20pt corner pads.
struct EdgeResizeOverlay: View {
    @EnvironmentObject private var state: AppState

    private let edge: CGFloat = 9
    private let corner: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Group {
                // Edges
                ResizerHandle(direction: .left, slideoutController: state.slideout)
                    .frame(width: edge, height: h - corner * 2)
                    .position(x: edge / 2, y: h / 2)
                ResizerHandle(direction: .right, slideoutController: state.slideout)
                    .frame(width: edge, height: h - corner * 2)
                    .position(x: w - edge / 2, y: h / 2)
                ResizerHandle(direction: .top, slideoutController: state.slideout)
                    .frame(width: w - corner * 2, height: edge)
                    .position(x: w / 2, y: edge / 2)
                ResizerHandle(direction: .bottom, slideoutController: state.slideout)
                    .frame(width: w - corner * 2, height: edge)
                    .position(x: w / 2, y: h - edge / 2)

                // Corners
                ResizerHandle(direction: .topLeft, slideoutController: state.slideout)
                    .frame(width: corner, height: corner)
                    .position(x: corner / 2, y: corner / 2)
                ResizerHandle(direction: .topRight, slideoutController: state.slideout)
                    .frame(width: corner, height: corner)
                    .position(x: w - corner / 2, y: corner / 2)
                ResizerHandle(direction: .bottomLeft, slideoutController: state.slideout)
                    .frame(width: corner, height: corner)
                    .position(x: corner / 2, y: h - corner / 2)
                ResizerHandle(direction: .bottomRight, slideoutController: state.slideout)
                    .frame(width: corner, height: corner)
                    .position(x: w - corner / 2, y: h - corner / 2)
            }
        }
        .allowsHitTesting(true)
    }
}
