import UIKit

/// Shared haptic feedback utility. Call `Haptics.prepare()` once at startup
/// (e.g., when the main view appears) to prewarm the generators so the first
/// triggered haptic has minimal latency.
///
/// All methods are `@MainActor` — UIImpactFeedbackGenerator must be created
/// and used on the main thread.
@MainActor
enum Haptics {

    private static let impactLight  = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)

    /// Prewarm both generators. Call once when the app's main UI appears.
    static func prepare() {
        impactLight.prepare()
        impactMedium.prepare()
    }

    /// Short light tap — icon buttons and toggles (resurface, aura fire, hide/unhide).
    static func lightTap() {
        impactLight.impactOccurred()
    }

    /// Medium tap — send and save confirmations (entry send, comment send, edit save).
    static func mediumTap() {
        impactMedium.impactOccurred()
    }
}
