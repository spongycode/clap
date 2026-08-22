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
    @Published public var placement: SlideoutPlacement = .right
    @Published public var state: SlideoutState = .closed

    public weak var window: NSWindow?

    private var windowAnimationOrigin: CGPoint?
    private var windowAnimationOriginBaseState: SlideoutState = .closed
    private var autoOpenTask: Task<Void, Never>?
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

    public func computePlacement(window: NSWindow, for size: NSSize) -> SlideoutPlacement {
        guard let screen = window.screen?.visibleFrame else { return placement }
        let windowFrame = window.frame
        if windowFrame.minX + size.width > screen.maxX {
            return .left
        } else {
            return .right
        }
    }

    public func openPreview(animated: Bool = true) {
        guard state != .open, state != .opening else { return }
        guard let window else { return }

        let targetSize = NSSize(width: contentWidth + slideoutWidth, height: window.frame.height)
        placement = computePlacement(window: window, for: targetSize)

        if animated {
            windowAnimationOrigin = window.frame.origin
            windowAnimationOriginBaseState = state

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
        guard state != .closed, state != .closing else { return }
        guard let window else { return }

        let targetSize = NSSize(width: contentWidth, height: window.frame.height)

        if animated {
            windowAnimationOrigin = window.frame.origin
            windowAnimationOriginBaseState = state

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
            var newOrigin = window.frame.origin
            if placement == .left && state == .open {
                newOrigin.x += slideoutWidth
            }
            state = .closed
            window.setFrame(NSRect(origin: newOrigin, size: targetSize), display: true)
        }
    }
}
