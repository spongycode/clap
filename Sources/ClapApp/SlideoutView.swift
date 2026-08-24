import SwiftUI
import AppKit

private struct ConditionalWidthModifier: ViewModifier {
    var width: CGFloat
    var condition: Bool

    func body(content: Content) -> some View {
        if condition {
            content.frame(width: width)
        } else {
            content
        }
    }
}

extension View {
    fileprivate func conditionalWidth(_ width: CGFloat, condition: Bool) -> some View {
        self.modifier(ConditionalWidthModifier(width: width, condition: condition))
    }
}

public struct SlideoutView<Content: View, Slideout: View>: View {
    @ObservedObject var controller: SlideoutController

    @ViewBuilder var content: () -> Content
    @ViewBuilder var slideout: () -> Slideout

    public init(
        controller: SlideoutController,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder slideout: @escaping () -> Slideout
    ) {
        self.controller = controller
        self.content = content
        self.slideout = slideout
    }

    private var leftToRight: Bool {
        controller.placement == .right
    }

    @ViewBuilder
    private func resizeDivider() -> some View {
        Divider()
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            // macOS 26 broke gestures when no background is present; the
            // near-invisible background is the workaround.
            .background(Color.white.opacity(0.001))
            .onHover { inside in
                if let window = controller.window {
                    window.isMovableByWindowBackground = !inside
                }
                if inside {
                    if #available(macOS 15.0, *) {
                        NSCursor.columnResize.push()
                    } else {
                        NSCursor.resizeLeftRight.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if let window = controller.window {
                            controller.slideoutWidth = min(
                                max(controller.minimumSlideoutWidth,
                                    controller.slideoutResizeWidth
                                        + (leftToRight ? -1 : 1) * value.translation.width),
                                window.frame.width - controller.minimumContentWidth)
                            controller.contentWidth = window.frame.width - controller.slideoutWidth
                        }
                    }
                    .onEnded { _ in
                        controller.slideoutWidth = controller.slideoutResizeWidth
                        controller.contentWidth = controller.contentResizeWidth
                    }
            )
            .disabled(controller.state != .open)
            .frame(maxWidth: 0)
            .opacity(controller.state != .closed ? 1 : 0)
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Main List Content Column
            VStack(spacing: 0) {
                content()
            }
            .environment(\.layoutDirection, .leftToRight)
            .frame(
                minWidth: controller.minimumContentWidth,
                idealWidth: controller.contentWidth.rounded(),
                alignment: .leading
            )
            .frame(width: controller.contentWidth.rounded())
            .fixedSize(horizontal: controller.state.isAnimating, vertical: false)
            .readWidth(controller, into: \.contentResizeWidth)

            // Draggable Divider between list and slideout preview
            resizeDivider()

            // Slideout Preview Column
            VStack(spacing: 0) {
                slideout()
                    .frame(
                        minWidth: controller.minimumSlideoutWidth,
                        idealWidth: controller.slideoutWidth.rounded(),
                        maxWidth: controller.slideoutWidth.rounded(),
                        alignment: .leading
                    )
                    .conditionalWidth(
                        controller.slideoutWidth.rounded(),
                        condition: controller.state.isAnimating
                    )
                    .transition(.identity)
            }
            .environment(\.layoutDirection, .leftToRight)
            .fixedSize(horizontal: controller.state.isAnimating, vertical: false)
            .readWidth(controller, into: \.slideoutResizeWidth)
            .frame(
                minWidth: controller.state != .open ? 0 : nil,
                maxWidth: controller.state == .closed ? 0 : nil
            )
            .clipped()
            .allowsHitTesting(controller.state != .closed)
        }
        .environment(\.layoutDirection, leftToRight ? .leftToRight : .rightToLeft)
    }
}
