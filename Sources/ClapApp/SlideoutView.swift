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

    @State private var dragStartContentWidth: CGFloat?
    @State private var dragStartSlideoutWidth: CGFloat?
    @State private var isDraggingDivider = false

    private var leftToRight: Bool {
        controller.placement == .right
    }

    @ViewBuilder
    private func resizeDivider() -> some View {
        Divider()
            .overlay(Color.primary.opacity(AppAlpha.Stroke.hairline))
            .padding(.horizontal, 6)
            .background(Color.white.opacity(0.001))
            .contentShape(Rectangle())
            .onHover { inside in
                if let window = controller.window {
                    window.isMovableByWindowBackground = !inside && !isDraggingDivider
                }
                if inside {
                    if #available(macOS 15.0, *) {
                        NSCursor.columnResize.push()
                    } else {
                        NSCursor.resizeLeftRight.push()
                    }
                } else if !isDraggingDivider {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartContentWidth == nil {
                            isDraggingDivider = true
                            dragStartContentWidth = controller.contentWidth
                            dragStartSlideoutWidth = controller.slideoutWidth
                            if let window = controller.window {
                                window.isMovableByWindowBackground = false
                            }
                        }
                        guard let startContent = dragStartContentWidth,
                              let startSlideout = dragStartSlideoutWidth else { return }

                        let total = startContent + startSlideout
                        let delta = (leftToRight ? 1 : -1) * value.translation.width
                        let rawContent = (startContent + delta).rounded()

                        let minContent = controller.minimumContentWidth
                        let maxContent = max(minContent, total - controller.minimumSlideoutWidth)

                        let clampedContent = min(maxContent, max(minContent, rawContent)).rounded()
                        let clampedSlideout = max(controller.minimumSlideoutWidth, total - clampedContent).rounded()

                        controller.contentWidth = clampedContent
                        controller.slideoutWidth = clampedSlideout
                    }
                    .onEnded { _ in
                        isDraggingDivider = false
                        dragStartContentWidth = nil
                        dragStartSlideoutWidth = nil
                        NSCursor.pop()
                        if let window = controller.window {
                            window.isMovableByWindowBackground = true
                        }
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
