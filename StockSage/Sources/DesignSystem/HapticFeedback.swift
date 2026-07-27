#if os(iOS)
import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Haptic Feedback (iOS enhancement, 2026-07-27)
//
// Provides contextual haptic feedback for critical trading actions on iOS.
// Uses impact, notification, and selection patterns appropriately:
//   - `.success` when a trade is journaled or closed profitably
//   - `.warning` when approaching a stop or invalid input
//   - `.error` when a trade closes at a loss or validation fails
//   - `.light` for UI interactions (button taps, segment changes)

enum HapticFeedback {
    enum Style {
        case success
        case warning
        case error
        case light
        case medium
        case heavy
        case selection
    }
    
    @MainActor
    static func trigger(_ style: Style) {
        #if os(iOS)
        switch style {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .light:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        }
        #endif
    }
}

// MARK: - View Extension for Haptic Feedback
extension View {
    /// Triggers haptic feedback when a button is pressed
    /// Usage: `Button("Action") { ... }.hapticFeedback(.light)`
    func hapticFeedback(_ style: HapticFeedback.Style, trigger: Bool = true) -> some View {
        onChange(of: trigger) { _, _ in
            HapticFeedback.trigger(style)
        }
    }
    
    /// Triggers haptic feedback on value changes
    /// Usage: `.hapticOnChange(of: selection, style: .selection)`
    func hapticOnChange<V: Equatable>(of value: V, style: HapticFeedback.Style) -> some View {
        onChange(of: value) { _, _ in
            HapticFeedback.trigger(style)
        }
    }
}

// MARK: - Button Style with Haptic Feedback
struct HapticButtonStyle: ButtonStyle {
    var style: HapticFeedback.Style = .light
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DS.Motion.spring, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    HapticFeedback.trigger(style)
                }
            }
    }
}
#endif
