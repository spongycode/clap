import SwiftUI
import AppKit

// MARK: - Panel background materials
//
// macOS 26 introduced Liquid Glass (NSGlassEffectView). On older systems we
// fall back to the classic popover vibrancy. Both fill the panel behind the
// SwiftUI content; the switch happens at runtime via AdaptivePanelBackground.

/// Classic pre-26 vibrancy.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Liquid Glass material (macOS 26+).
@available(macOS 26.0, *)
struct LiquidGlassBackground: NSViewRepresentable {
    var style: NSGlassEffectView.Style = .regular

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = style
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.style = style
    }
}

/// Picks the best available panel material for the running OS.
struct AdaptivePanelBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            LiquidGlassBackground()
        } else {
            VisualEffectBackground()
        }
    }
}
