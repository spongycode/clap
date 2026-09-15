import AppKit

/// Sensory confirmation for successful copies: a subtle system sound plus a
/// trackpad haptic tick. Both are best-effort — silence on any failure.
enum CopyFeedback {
    private static let sound = NSSound(named: "Pop")

    static func play() {
        sound?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment, performanceTime: .now)
    }
}
