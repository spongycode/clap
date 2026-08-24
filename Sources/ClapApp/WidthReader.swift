import SwiftUI

/// Measures a view's rendered width and writes it back. Used by
/// SlideoutView's divider so drag end-states reset to actually-rendered
/// widths.
struct SizeReaderModifier<Value: Equatable>: ViewModifier {
    @Binding var value: Value
    let mapper: (CGSize) -> Value

    func body(content: Content) -> some View {
        content.onGeometryChange(for: Value.self) { proxy in
            mapper(proxy.size)
        } action: { newValue in
            value = newValue
        }
    }
}

extension View {
    func readWidth(
        _ state: SlideoutController,
        into keyPath: ReferenceWritableKeyPath<SlideoutController, CGFloat>
    ) -> some View {
        readWidth(Binding(
            get: { state[keyPath: keyPath] },
            set: { state[keyPath: keyPath] = $0 }
        ))
    }

    func readWidth(_ value: Binding<CGFloat>) -> some View {
        modifier(SizeReaderModifier(value: value, mapper: \.width))
    }
}
