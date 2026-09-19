import SwiftUI

/// Motion tokens. Movement always answers a change of state; nothing moves for decoration
/// except the orb, and under Reduce Motion everything becomes a short cross-fade.
enum Motion {
    /// Press states and small toggles.
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.86)
    /// Layout changes: cards arriving, the orb stepping back.
    static let smooth = Animation.spring(response: 0.5, dampingFraction: 0.88)
    /// Slow ambient changes (backdrop tint).
    static let gentle = Animation.easeInOut(duration: 0.8)
    /// Reduce Motion replacement for every spring.
    static let fade = Animation.easeInOut(duration: 0.2)

    static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }
}

extension AnyTransition {
    /// A card rising a few points into place; a plain cross-fade under Reduce Motion.
    static func rise(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 28).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.97))
        )
    }

    /// A banner dropping in from the top edge.
    static func drop(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
}

// MARK: - Haptics

extension EnvironmentValues {
    /// Mirrors Settings → Voice → Haptics. Set it once near the root:
    /// `.environment(\.hapticsEnabled, settings.hapticsEnabled)`.
    @Entry var hapticsEnabled: Bool = true
}

extension View {
    /// Plays `feedback` when `trigger` changes, unless haptics are turned off in Settings.
    func haptic<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        modifier(HapticModifier(trigger: trigger) { _, _ in feedback })
    }

    /// Chooses the feedback from the old and new trigger values (nil plays nothing).
    func haptic<T: Equatable>(trigger: T, _ feedback: @escaping (T, T) -> SensoryFeedback?) -> some View {
        modifier(HapticModifier(trigger: trigger, feedback: feedback))
    }
}

private struct HapticModifier<T: Equatable>: ViewModifier {
    let trigger: T
    let feedback: (T, T) -> SensoryFeedback?
    @Environment(\.hapticsEnabled) private var hapticsEnabled

    func body(content: Content) -> some View {
        let enabled = hapticsEnabled
        let feedback = feedback
        return content.sensoryFeedback(trigger: trigger) { old, new in
            enabled ? feedback(old, new) : nil
        }
    }
}
