//
//  ReminderNotifications.swift
//  kebab
//

import Foundation
import UIKit
import UserNotifications

/// OS permission reality, collapsed to the three states the UI reasons
/// about. Provisional/ephemeral count as authorized — delivery works.
nonisolated enum ReminderAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied

    var canDeliver: Bool { self == .authorized }
}

/// One scheduled delivery. The store builds these from the durable record;
/// the scheduler is a dumb sink so it can be faked in tests.
nonisolated struct ReminderNotificationRequest: Equatable, Sendable {
    let entryId: UUID
    let fireAt: Date
    let title: String
    let body: String
}

/// The delivery mechanism, abstracted so reminder logic is testable without
/// the notification centre (and so the store can never accidentally treat
/// pending requests as its source of truth).
protocol ReminderScheduling: Sendable {
    func authorizationStatus() async -> ReminderAuthorization
    func requestAuthorization() async -> ReminderAuthorization
    func schedule(_ request: ReminderNotificationRequest) async
    func cancel(entryIds: [UUID]) async
    func cancelAll() async
    /// Entry ids that currently have a pending (undelivered) request —
    /// used to reconcile scheduling against the durable records.
    func pendingEntryIds() async -> Set<UUID>
}

/// Notification copy. One canonical title for every reminder, Random
/// included: the delivered notification never reveals how it was scheduled.
nonisolated enum ReminderNotificationContent {

    static let title = "You wanted this back"
    private static let bodyCharacterLimit = 120

    /// The note wins when there is one — it is the user's own words about
    /// why they wanted this back. Otherwise a sensible excerpt of whatever
    /// the entry actually is.
    static func body(for entry: Entry, note: String?) -> String {
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return truncated(note)
        }
        return excerpt(of: entry)
    }

    static func excerpt(of entry: Entry) -> String {
        if entry.isContentHidden {
            return "A hidden entry."
        }
        let text = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            // Checklists read as their first item rather than a marker line.
            let flattened = Checklist.hasChecklist(text)
                ? checklistExcerpt(text)
                : text
            if !flattened.isEmpty { return truncated(flattened) }
        }
        if let link = entry.linkAttachment {
            if let title = link.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                return truncated(title)
            }
            if let host = URL(string: link.url)?.host {
                return truncated(host)
            }
            return truncated(link.url)
        }
        let images = entry.imageAttachments.count
        if images == 1 { return "A photo you saved." }
        if images > 1 { return "\(images) photos you saved." }
        return "An entry you saved."
    }

    private static func checklistExcerpt(_ text: String) -> String {
        for segment in Checklist.segments(of: text) {
            switch segment {
            case .text(_, let block):
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case .item(_, _, let itemText, _):
                let trimmed = itemText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    private static func truncated(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > bodyCharacterLimit else { return collapsed }
        let clipped = collapsed.prefix(bodyCharacterLimit)
        // Prefer a word boundary so the excerpt reads as a sentence fragment,
        // not a hard cut mid-word.
        if let lastSpace = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: lastSpace) > 40 {
            return clipped[clipped.startIndex..<lastSpace] + "\u{2026}"
        }
        return clipped + "\u{2026}"
    }
}

/// `UNUserNotificationCenter`-backed delivery.
///
/// Identity is the entry id: one request per entry, and re-scheduling the
/// same entry replaces its request rather than stacking a second one — the
/// structural guarantee behind "one active reminder per entry, no duplicates".
nonisolated struct UserNotificationScheduler: ReminderScheduling {

    static let identifierPrefix = "kebab.reminder."
    static let entryIdKey = "kebab.reminder.entryId"

    private var center: UNUserNotificationCenter { .current() }

    static func identifier(for entryId: UUID) -> String {
        identifierPrefix + entryId.uuidString
    }

    static func entryId(fromIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(identifierPrefix.count)))
    }

    func authorizationStatus() async -> ReminderAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .authorized, .provisional, .ephemeral:
            return .authorized
        default:
            return .denied
        }
    }

    func requestAuthorization() async -> ReminderAuthorization {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted ? .authorized : .denied
        } catch {
            return .denied
        }
    }

    func schedule(_ request: ReminderNotificationRequest) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.userInfo = [Self.entryIdKey: request.entryId.uuidString]

        // Calendar components (not a raw interval) so the reminder keeps its
        // wall-clock intent through a daylight-saving transition.
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: request.fireAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let notification = UNNotificationRequest(
            identifier: Self.identifier(for: request.entryId),
            content: content,
            trigger: trigger
        )
        // Same identifier replaces in place — never a second delivery.
        try? await center.add(notification)
    }

    func cancel(entryIds: [UUID]) async {
        let identifiers = entryIds.map(Self.identifier(for:))
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func cancelAll() async {
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        let delivered = await center.deliveredNotifications()
            .map(\.request.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }

    func pendingEntryIds() async -> Set<UUID> {
        let requests = await center.pendingNotificationRequests()
        return Set(requests.compactMap { Self.entryId(fromIdentifier: $0.identifier) })
    }
}

/// What the notification layer hands back to the app.
@MainActor
protocol ReminderEventReceiving: AnyObject {
    /// The user tapped a reminder notification — deep-link to that entry.
    func handleReminderTap(entryId: UUID)
    /// A reminder came due while the app was in the foreground. Returns
    /// true when the app handled the presentation itself (in-app banner, or
    /// deliberate silence because the user is already on that entry).
    func handleForegroundDelivery(entryId: UUID) -> Bool
}

/// Buffers notification events until the app's reminder store exists.
///
/// A cold launch from a notification tap delivers the response before any
/// SwiftUI state is alive; holding the entry id here and replaying it on
/// attach is what makes that path land on the right entry every time.
@MainActor
final class ReminderNotificationBridge {

    static let shared = ReminderNotificationBridge()

    private weak var receiver: ReminderEventReceiving?
    private var bufferedTapEntryId: UUID?

    /// The app always uses `shared`; the initializer is reachable so the
    /// buffer/replay behavior can be tested without global state.
    init() {}

    func attach(_ receiver: ReminderEventReceiving) {
        self.receiver = receiver
        if let buffered = bufferedTapEntryId {
            bufferedTapEntryId = nil
            receiver.handleReminderTap(entryId: buffered)
        }
    }

    func detach(_ receiver: ReminderEventReceiving) {
        if self.receiver === receiver { self.receiver = nil }
    }

    func receiveTap(entryId: UUID) {
        if let receiver {
            receiver.handleReminderTap(entryId: entryId)
        } else {
            bufferedTapEntryId = entryId
        }
    }

    func receiveForegroundDelivery(entryId: UUID) -> Bool {
        receiver?.handleForegroundDelivery(entryId: entryId) ?? false
    }
}

/// The notification-centre delegate. Installed at launch (before the first
/// frame) so a tap that cold-launched the app is never dropped.
final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    static let shared = ReminderNotificationDelegate()

    /// Call once, as early as possible in the launch sequence.
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    private func entryId(from notification: UNNotification) -> UUID? {
        if let raw = notification.request.content.userInfo[UserNotificationScheduler.entryIdKey] as? String,
           let id = UUID(uuidString: raw) {
            return id
        }
        return UserNotificationScheduler.entryId(fromIdentifier: notification.request.identifier)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let entryId = entryId(from: response.notification) else { return }
        await MainActor.run {
            ReminderNotificationBridge.shared.receiveTap(entryId: entryId)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard let entryId = entryId(from: notification) else { return [] }
        let handledInApp = await MainActor.run {
            ReminderNotificationBridge.shared.receiveForegroundDelivery(entryId: entryId)
        }
        // Kebab presents its own quiet in-app banner (or deliberately
        // nothing when the user is already on the entry) — never the system
        // banner on top of the app.
        return handledInApp ? [] : [.banner, .sound]
    }
}
