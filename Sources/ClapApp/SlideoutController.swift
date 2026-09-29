import AppKit
import SwiftUI

public enum SlideoutState: Equatable, Sendable {
    case opening
    case closing
    case open
    case closed

    public var isAnimating: Bool {
        switch self {
        case .closed, .open: return false
        case .opening, .closing: return true
        }
    }

    public var isOpen: Bool {
        switch self {
        case .open, .opening: return true
        case .closed, .closing: return false
        }
    }

    public func animationDone() -> SlideoutState {
        switch self {
        case .open, .opening: return .open
        case .closed, .closing: return .closed
        }
    }
}

public enum SlideoutPlacement: String, Equatable, Sendable {
    case left
    case right
}

@MainActor
public final class SlideoutController: ObservableObject {
    public static let animationDuration: Double = 0.28

    public let minimumContentWidth: CGFloat = 460
    public let minimumSlideoutWidth: CGFloat = 320

    @Published public var contentWidth: CGFloat = 480
    @Published public var slideoutWidth: CGFloat = 360

    // Last RENDERED widths, written continuously by readWidth in
    // SlideoutView. Divider drag-end resets to these so the settled layout
    // always matches what is actually on screen.
    var contentResizeWidth: CGFloat = 0
    var slideoutResizeWidth: CGFloat = 0
    @Published public var placement: SlideoutPlacement = .right
    @Published public var state: SlideoutState = .closed

    public weak var window: NSWindow?

    private var windowAnimationOrigin: CGPoint?
    private var autoOpenTask: Task<Void, Never>?
    private var closeIfEmptyTask: Task<Void, Never>?
    public var autoOpenDelayMs: Int = 1000

    public init() {}

    public func startAutoOpen(delayMs: Int? = nil) {
        cancelAutoOpen()
        guard !state.isOpen else { return }

        let delay = delayMs ?? autoOpenDelayMs
        autoOpenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if !self.state.isOpen {
                self.openPreview(animated: true)
            }
        }
    }

    public func cancelAutoOpen() {
        autoOpenTask?.cancel()
        autoOpenTask = nil
    }

    /// Tab switches momentarily clear the selection before the new tab's
    /// first row is auto-selected. Close only if NO selection arrives within
    /// the grace period (i.e. the tab is genuinely empty) — otherwise the
    /// pane stays open and its content updates in place.
    public func scheduleCloseIfNoSelection(delayMs: Int = 250) {
        closeIfEmptyTask?.cancel()
        closeIfEmptyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.state.isOpen else { return }
            self.closePreview(animated: true)
        }
    }

    public func cancelCloseIfNoSelection() {
        closeIfEmptyTask?.cancel()
        closeIfEmptyTask = nil
    }

    public func computePlacement(window: NSWindow, for size: NSSize) -> SlideoutPlacement {
        guard let screen = window.screen?.visibleFrame else { return placement }
        return Self.placement(listFrame: window.frame, totalWidth: size.width, screen: screen)
    }

    /// Right if the widened window fits on screen, else left if that fits,
    /// else whichever side overflows less (a narrow screen fits neither).
    static func placement(listFrame: NSRect, totalWidth: CGFloat, screen: NSRect) -> SlideoutPlacement {
        let extra = totalWidth - listFrame.width
        let rightOverflow = max(0, listFrame.minX + totalWidth - screen.maxX)
        let leftOverflow = max(0, screen.minX - (listFrame.minX - extra))
        if rightOverflow == 0 { return .right }
        if leftOverflow == 0 { return .left }
        return leftOverflow < rightOverflow ? .left : .right
    }

    /// Screen rect of the list column alone, whatever the preview's state.
    /// This is what gets persisted as the panel's frame: the list is the
    /// anchor, the preview is transient.
    func listFrame(of window: NSWindow) -> NSRect {
        var frame = window.frame
        if state.isOpen, placement == .left {
            frame.origin.x = frame.maxX - contentWidth
        }
        frame.size.width = state.isOpen ? contentWidth : frame.width
        return frame
    }

    public func openPreview(animated: Bool = true) {
        guard state != .open, state != .opening else { return }
        guard let window else { return }

        let targetSize = NSSize(width: contentWidth + slideoutWidth, height: window.frame.height)
        placement = computePlacement(window: window, for: targetSize)

        if animated {
            windowAnimationOrigin = window.frame.origin

            withAnimation(.easeInOut(duration: Self.animationDuration)) {
                state = .opening

                var newOrigin = windowAnimationOrigin ?? window.frame.origin
                if placement == .left {
                    newOrigin.x -= slideoutWidth
                }

                let targetFrame = NSRect(origin: newOrigin, size: targetSize)

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.animationDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    context.completionHandler = { [weak self] in
                        guard let self else { return }
                        if self.state == .opening {
                            self.state = .open
                        }
                    }
                    window.animator().setFrame(targetFrame, display: true)
                }
            }
        } else {
            var newOrigin = window.frame.origin
            if placement == .left && state == .closed {
                newOrigin.x -= slideoutWidth
            }
            state = .open
            window.setFrame(NSRect(origin: newOrigin, size: targetSize), display: true)
        }
    }

    public func closePreview(animated: Bool = true) {
        guard state != .closed else { return }
        // An animated close already in flight is fine to leave running; an
        // instant close must still take over from it (e.g. hiding mid-close).
        if animated, state == .closing { return }
        guard let window else { return }

        let targetSize = NSSize(width: contentWidth, height: window.frame.height)

        if animated {
            windowAnimationOrigin = window.frame.origin

            withAnimation(.easeInOut(duration: Self.animationDuration)) {
                state = .closing

                var newOrigin = windowAnimationOrigin ?? window.frame.origin
                if placement == .left {
                    newOrigin.x += slideoutWidth
                }

                let targetFrame = NSRect(origin: newOrigin, size: targetSize)

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.animationDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    context.completionHandler = { [weak self] in
                        guard let self else { return }
                        if self.state == .closing {
                            self.state = .closed
                        }
                    }
                    window.animator().setFrame(targetFrame, display: true)
                }
            }
        } else {
            closeImmediately(window: window, targetSize: targetSize)
        }
    }

    /// Instant close from ANY non-closed state. Handles hiding mid-animation:
    /// the list's position comes from the pre-animation origin rather than
    /// the half-animated frame, and the in-flight frame animation is
    /// superseded so it can't keep widening the window after we've settled it.
    private func closeImmediately(window: NSWindow, targetSize: NSSize) {
        var newOrigin = window.frame.origin
        switch state {
        case .opening, .closing:
            // Both animations started from the list's own origin.
            newOrigin = windowAnimationOrigin ?? newOrigin
            if state == .closing, placement == .left {
                newOrigin.x += slideoutWidth
            }
        case .open:
            if placement == .left { newOrigin.x += slideoutWidth }
        case .closed:
            break
        }
        state = .closed
        let target = NSRect(origin: newOrigin, size: targetSize)
        // A zero-duration animator write replaces any running frame animation;
        // a plain setFrame would be overwritten by the animation's next tick.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().setFrame(target, display: true)
        }
        window.setFrame(target, display: true)
    }
}
