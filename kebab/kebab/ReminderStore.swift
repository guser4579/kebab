//
//  ReminderStore.swift
//  kebab
//

import Combine
import Foundation

/// Server persistence for reminders, abstracted for tests.
protocol ReminderSyncing: AnyObject {
    func fetchAll() async throws -> [EntryReminder]
    func upsert(_ reminder: EntryReminder) async throws
    func delete(entryId: UUID) async throws
}

extension ReminderRepository: ReminderSyncing {}

/// Disk mirror of the reminder set, abstracted for tests.
protocol ReminderPersisting: AnyObject {
    func load(key: String) -> ReminderMirror?
    func save(_ mirror: ReminderMirror, key: String)
}

/// What survives app termination on-device: the records themselves, the
/// per-record sync intent, and the notification bodies (so a reminder can be
/// re-scheduled offline without re-reading the entry).
nonisolated struct ReminderMirror: Codable, Equatable {
    var reminders: [EntryReminder] = []
    var pendingSyncIds: [UUID] = []
    var pendingDeleteIds: [UUID] = []
    var bodies: [String: String] = [:]
}

final class LocalStoreReminderPersistence: ReminderPersisting {
    func load(key: String) -> ReminderMirror? {
        LocalStore.load(ReminderMirror.self, from: key)
    }

    func save(_ mirror: ReminderMirror, key: String) {
        LocalStore.save(mirror, as: key)
    }
}

nonisolated enum ReminderSaveOutcome: Equatable {
    case saved(EntryReminder)
    /// The OS will not deliver — the reminder is deliberately NOT persisted,
    /// because Kebab never claims a reminder it cannot deliver.
    case permissionDenied
    case notConfigured
}

/// The reminder system's single source of truth.
///
/// Durability model, deliberately the same shape as the rest of Kebab:
/// the record lives in Supabase (`entry_reminders`, one row per entry), a
/// local mirror makes it offline-complete and instant to read, and iOS local
/// notifications are only the delivery mechanism — scheduling is reconciled
/// *from* the records on every launch and foreground, never trusted as
/// state. Nothing about a reminder's lifecycle is inferred from whether a
/// notification request happens to exist.
@MainActor
final class ReminderStore: ObservableObject, ReminderEventReceiving {

    /// A reminder that came due while the app was open and the user was
    /// somewhere else — drives the lightweight in-app banner.
    struct ForegroundDelivery: Identifiable, Equatable {
        let id = UUID()
        let entryId: UUID
        let body: String
    }

    @Published private(set) var reminders: [UUID: EntryReminder] = [:]
    @Published private(set) var authorization: ReminderAuthorization = .notDetermined
    /// Set when a reminder notification is tapped; the app deep-links into
    /// this entry's normal detail screen and clears it.
    @Published var deepLinkEntryId: UUID?
    @Published var foregroundDelivery: ForegroundDelivery?
    /// Bumped whenever a reminder crosses its fire time (or state is
    /// otherwise re-derived) so time-derived UI re-renders without polling.
    @Published private(set) var clockTick: Int = 0

    /// The entry on screen right now. A reminder for it fires silently —
    /// the user is already where the reminder wanted to take them.
    var currentlyViewedEntryId: UUID?
    /// Resolves an entry for notification copy when the local body cache
    /// misses (e.g. a record synced from another device).
    var entryProvider: ((UUID) -> Entry?)?

    private let repository: ReminderSyncing
    private let scheduler: ReminderScheduling
    private let persistence: ReminderPersisting
    private let now: () -> Date

    private var userId: UUID?
    private var pendingSyncIds: Set<UUID> = []
    private var pendingDeleteIds: Set<UUID> = []
    private var bodies: [UUID: String] = [:]

    private var storageKey: String {
        "reminders_\(userId?.uuidString ?? "anonymous")"
    }

    init(
        repository: ReminderSyncing,
        scheduler: ReminderScheduling = UserNotificationScheduler(),
        persistence: ReminderPersisting = LocalStoreReminderPersistence(),
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.scheduler = scheduler
        self.persistence = persistence
        self.now = now
    }

    // MARK: - Lifecycle

    /// Binds the store to an account and hydrates from disk. Reminders are
    /// keyed per user, like the other local history stores.
    func configure(userId: UUID) {
        guard self.userId != userId else { return }
        self.userId = userId
        hydrate()
        ReminderNotificationBridge.shared.attach(self)
        Task { await refresh() }
    }

    private func hydrate() {
        guard let mirror = persistence.load(key: storageKey) else { return }
        reminders = Dictionary(
            mirror.reminders.map { ($0.entryId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        pendingSyncIds = Set(mirror.pendingSyncIds)
        pendingDeleteIds = Set(mirror.pendingDeleteIds)
        bodies = Dictionary(
            mirror.bodies.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func persist() {
        let mirror = ReminderMirror(
            reminders: Array(reminders.values),
            pendingSyncIds: Array(pendingSyncIds),
            pendingDeleteIds: Array(pendingDeleteIds),
            bodies: Dictionary(
                bodies.map { ($0.key.uuidString, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        persistence.save(mirror, key: storageKey)
    }

    // MARK: - Reads

    func reminder(for entryId: UUID) -> EntryReminder? {
        reminders[entryId]
    }

    /// The reminder the entry points should reopen: only one that still owes
    /// a delivery. A fired reminder has finished its job, so "Remind me"
    /// starts a fresh one.
    func activeReminder(for entryId: UUID) -> EntryReminder? {
        guard let reminder = reminders[entryId], reminder.isActive(now: now()) else { return nil }
        return reminder
    }

    func lifecycle(for entryId: UUID) -> EntryReminder.Lifecycle? {
        reminders[entryId]?.lifecycle(now: now())
    }

    /// The delivered note still owed to the user on this entry, if any.
    func pendingNote(for entryId: UUID) -> String? {
        reminders[entryId]?.pendingNoteContext(now: now())
    }

    // MARK: - Permission

    func refreshAuthorization() async {
        authorization = await scheduler.authorizationStatus()
    }

    /// Contextual permission request — only ever called at the moment the
    /// user actually tries to set a reminder.
    private func ensureAuthorization() async -> ReminderAuthorization {
        var status = await scheduler.authorizationStatus()
        if status == .notDetermined {
            status = await scheduler.requestAuthorization()
        }
        authorization = status
        return status
    }

    // MARK: - Writes

    /// Creates or replaces the entry's reminder. One record per entry, so
    /// this is always a replacement, never an addition.
    ///
    /// Returns `.permissionDenied` — and writes nothing — when the OS won't
    /// deliver, so the UI can tell the truth instead of pretending.
    func save(
        entry: Entry,
        mode: ReminderMode,
        fireAt: Date,
        note: String?
    ) async -> ReminderSaveOutcome {
        guard let userId else { return .notConfigured }
        let status = await ensureAuthorization()
        guard status.canDeliver else { return .permissionDenied }

        let existing = reminders[entry.id]
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reminder = EntryReminder(
            entryId: entry.id,
            userId: userId,
            fireAt: fireAt,
            mode: mode,
            note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote,
            createdAt: existing?.createdAt ?? now(),
            // A newly set reminder starts a fresh cycle: nothing delivered,
            // nothing acknowledged, no stale note context left behind.
            acknowledgedAt: nil,
            noteDismissedAt: nil
        )

        reminders[entry.id] = reminder
        bodies[entry.id] = ReminderNotificationContent.body(for: entry, note: reminder.trimmedNote)
        pendingDeleteIds.remove(entry.id)
        pendingSyncIds.insert(entry.id)
        persist()

        await scheduleDelivery(for: reminder)
        await pushUpsert(reminder)
        return .saved(reminder)
    }

    /// Removes the reminder entirely: delivery cancelled, metadata cleared,
    /// every affordance gone. The entry itself is untouched.
    func removeReminder(entryId: UUID) async {
        guard reminders[entryId] != nil else { return }
        reminders[entryId] = nil
        bodies[entryId] = nil
        pendingSyncIds.remove(entryId)
        pendingDeleteIds.insert(entryId)
        if foregroundDelivery?.entryId == entryId { foregroundDelivery = nil }
        persist()

        await scheduler.cancel(entryIds: [entryId])
        await pushDelete(entryId: entryId)
    }

    /// The user revisited a delivered entry — the unread state ends here.
    func markOpened(entryId: UUID) {
        guard var reminder = reminders[entryId] else { return }
        guard reminder.fireAt <= now(), reminder.acknowledgedAt == nil else { return }
        reminder.acknowledgedAt = now()
        reminders[entryId] = reminder
        pendingSyncIds.insert(entryId)
        if foregroundDelivery?.entryId == entryId { foregroundDelivery = nil }
        persist()
        Task { await pushUpsert(reminder) }
    }

    /// The user dismissed the delivered note banner — the last piece of
    /// reminder UI for this entry goes away.
    func dismissNote(entryId: UUID) {
        guard var reminder = reminders[entryId], reminder.noteDismissedAt == nil else { return }
        reminder.noteDismissedAt = now()
        reminders[entryId] = reminder
        pendingSyncIds.insert(entryId)
        persist()
        Task { await pushUpsert(reminder) }
    }

    /// Entry deletion cleanup: cancel delivery, drop the metadata, and
    /// tombstone the id.
    ///
    /// The server row cascades with the entry, but the tombstone matters
    /// anyway: without it a refresh that races the cascade would re-adopt
    /// the row and reschedule a delivery for an entry that no longer
    /// exists. Called only after a delete the server confirmed.
    func handleEntryDeleted(id: UUID) {
        guard reminders[id] != nil else { return }
        reminders[id] = nil
        bodies[id] = nil
        pendingSyncIds.remove(id)
        pendingDeleteIds.insert(id)
        if deepLinkEntryId == id { deepLinkEntryId = nil }
        if foregroundDelivery?.entryId == id { foregroundDelivery = nil }
        persist()
        Task {
            await scheduler.cancel(entryIds: [id])
            await pushDelete(entryId: id)
        }
    }

    // MARK: - Sync

    /// Server reconciliation plus scheduling reconciliation. Cheap enough to
    /// run on every foreground; silent when offline (the mirror stays
    /// authoritative).
    func refresh() async {
        guard userId != nil else { return }
        await refreshAuthorization()
        await flushPendingWrites()

        do {
            let serverRows = try await repository.fetchAll()
            var merged: [UUID: EntryReminder] = [:]
            for row in serverRows where !pendingDeleteIds.contains(row.entryId) {
                merged[row.entryId] = row
            }
            // Local writes that haven't reached the server yet outrank the
            // server's older copy.
            for id in pendingSyncIds {
                if let local = reminders[id] { merged[id] = local }
            }
            reminders = merged
            bodies = bodies.filter { merged[$0.key] != nil }
            persist()
        } catch {
            // Offline: the mirror remains the truth. Scheduling still gets
            // reconciled below from whatever we hold.
        }

        clockTick += 1
        await reconcileScheduling()
    }

    private func flushPendingWrites() async {
        for id in pendingDeleteIds {
            do {
                try await repository.delete(entryId: id)
                pendingDeleteIds.remove(id)
            } catch {
                // Retried on the next refresh.
            }
        }
        for id in pendingSyncIds {
            guard let reminder = reminders[id] else {
                pendingSyncIds.remove(id)
                continue
            }
            do {
                try await repository.upsert(reminder)
                pendingSyncIds.remove(id)
            } catch {
                // Retried on the next refresh.
            }
        }
        persist()
    }

    private func pushUpsert(_ reminder: EntryReminder) async {
        do {
            try await repository.upsert(reminder)
            pendingSyncIds.remove(reminder.entryId)
            persist()
        } catch {
            // Stays queued; the next refresh retries.
        }
    }

    private func pushDelete(entryId: UUID) async {
        do {
            try await repository.delete(entryId: entryId)
            pendingDeleteIds.remove(entryId)
            persist()
        } catch {
            // Stays queued; the next refresh retries.
        }
    }

    /// Brings the notification centre in line with the records: every
    /// still-scheduled reminder has exactly one pending request, and nothing
    /// else does. This is what makes a reinstall-free relaunch, a device
    /// restart, or a record synced from another device end up scheduled —
    /// and what guarantees no ghost deliveries after removal or firing.
    private func reconcileScheduling() async {
        let pending = await scheduler.pendingEntryIds()
        let live = reminders.values.filter { $0.fireAt > now() }
        let liveIds = Set(live.map(\.entryId))

        for reminder in live where !pending.contains(reminder.entryId) {
            await scheduleDelivery(for: reminder)
        }
        let orphans = pending.subtracting(liveIds)
        if !orphans.isEmpty {
            await scheduler.cancel(entryIds: Array(orphans))
        }
    }

    private func scheduleDelivery(for reminder: EntryReminder) async {
        await scheduler.schedule(
            ReminderNotificationRequest(
                entryId: reminder.entryId,
                fireAt: reminder.fireAt,
                title: ReminderNotificationContent.title,
                body: notificationBody(for: reminder)
            )
        )
    }

    private func notificationBody(for reminder: EntryReminder) -> String {
        if let note = reminder.trimmedNote { return note }
        if let cached = bodies[reminder.entryId] { return cached }
        if let entry = entryProvider?(reminder.entryId) {
            let body = ReminderNotificationContent.body(for: entry, note: nil)
            bodies[reminder.entryId] = body
            return body
        }
        return "An entry you saved."
    }

    // MARK: - Notification events

    func handleReminderTap(entryId: UUID) {
        clockTick += 1
        foregroundDelivery = nil
        deepLinkEntryId = entryId
    }

    func handleForegroundDelivery(entryId: UUID) -> Bool {
        // Time-derived state just changed for this entry.
        clockTick += 1
        guard reminders[entryId] != nil else {
            // Delivery for something we no longer track (removed elsewhere,
            // entry deleted): swallow it rather than show a dead banner.
            return true
        }
        if currentlyViewedEntryId == entryId {
            // Already exactly where the reminder wanted to bring them: no
            // banner, no interruption. The note banner (if any) appears in
            // the entry on its own.
            markOpened(entryId: entryId)
            return true
        }
        foregroundDelivery = ForegroundDelivery(
            entryId: entryId,
            body: reminders[entryId].flatMap { notificationBody(for: $0) } ?? "An entry you saved."
        )
        return true
    }

    // MARK: - Session end

    /// Reminder delivery must not survive a session: a queued notification
    /// belongs to the account that scheduled it. The local mirror is wiped
    /// with the rest of the cache directory by `LocalStore.removeAll()`.
    nonisolated static func cancelAllDeliveryForSessionEnd() {
        let scheduler = UserNotificationScheduler()
        Task { await scheduler.cancelAll() }
    }
}
