//
//  ReminderAffordanceView.swift
//  kebab
//

import SwiftUI

/// The quiet active-reminder mark: a clock and a human-readable time, or
/// simply "Random" when Kebab is keeping the time to itself. Metadata, not a
/// badge — same secondary voice as the timestamp beside it. Tapping reopens
/// the reminder editor.
struct ReminderAffordanceView: View {

    let reminder: EntryReminder
    let canDeliver: Bool
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            // Same grammar as the resurface/fire counters beside it: a
            // small glyph in the standard icon grid, then meta text.
            HStack(spacing: 0) {
                Icon("clock-01", glyphSize: Style.Icon.glyphSmall)
                    .foregroundColor(Style.Color.secondary)

                Text(ReminderDisplay.affordanceLabel(for: reminder, canDeliver: canDeliver))
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .accessibilityLabel(
            "Reminder, \(ReminderDisplay.affordanceLabel(for: reminder, canDeliver: canDeliver))"
        )
    }
}

/// Fired-but-not-yet-revisited state in the feed. Deliberately the smallest
/// thing that still says "this came back for you": a dot, plus the row's own
/// slight highlight. No count, no label, no color alarm.
struct ReminderUnreadDot: View {
    var body: some View {
        Circle()
            .fill(Style.Color.primaryText.opacity(0.85))
            .frame(width: 6, height: 6)
            .accessibilityLabel("Came back for you")
    }
}

/// The delivered reminder's note, shown inside the entry below the root
/// content and above the comments. Contextual entry metadata, not an alert:
/// it never auto-dismisses and never becomes a comment.
struct ReminderNoteBannerView: View {

    let note: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Style.Spacing.x3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ReminderNotificationContent.title)
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.secondary)

                Text(note)
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Style.Color.secondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-2)
            .accessibilityLabel("Dismiss reminder note")
        }
        .padding(Style.Spacing.x4)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Style.Color.composerBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Style.Color.separator, lineWidth: 1)
                )
        )
        .padding(.horizontal, Style.Layout.entryContentPadding)
        .padding(.vertical, Style.Spacing.x3)
    }
}

/// A reminder that came due while Kebab was open and the user was elsewhere.
/// Same words as the push notification, in the app's own voice — subtle,
/// temporary, tappable.
struct ReminderInAppBannerView: View {

    let body_: String
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(alignment: .top, spacing: Style.Spacing.x3) {
                Icon("clock-01", glyphSize: Style.Icon.glyphSmall)
                    .foregroundColor(Style.Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(ReminderNotificationContent.title)
                        .font(.custom("DMSans-Medium", size: 14))
                        .foregroundColor(Style.Color.primaryText)

                    Text(body_)
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .padding(Style.Spacing.x3)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Style.Color.composerBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Style.Color.separator, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 4)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Style.Layout.entryContentPadding)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < -20 { onDismiss() }
                }
        )
    }
}
