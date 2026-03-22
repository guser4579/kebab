import UIKit

/// Shared haptic feedback utility. Call `Haptics.prepare()` once at startup
/// (e.g., when the main view appears) to prewarm the generators so the first
/// triggered haptic has minimal latency.
///
/// All methods are `@MainActor` — UIKit feedback generators must be created
/// and used on the main thread.
@MainActor
enum Haptics {

    private static let impactLight    = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium   = UIImpactFeedbackGenerator(style: .medium)
    private static let notificationFB = UINotificationFeedbackGenerator()

    /// Prewarm all generators. Call once when the app's main UI appears.
    static func prepare() {
        impactLight.prepare()
        impactMedium.prepare()
        notificationFB.prepare()
    }

    /// Short light tap — icon buttons and toggles (resurface, aura fire, hide/unhide, pin, link launch).
    static func lightTap() {
        impactLight.impactOccurred()
    }

    /// Medium tap — send and save confirmations (entry send, comment send, edit save).
    static func mediumTap() {
        impactMedium.impactOccurred()
    }

    /// Warning notification — committed destructive actions (delete).
    static func destructiveTap() {
        notificationFB.notificationOccurred(.warning)
    }
}
