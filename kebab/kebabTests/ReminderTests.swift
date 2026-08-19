//
//  ReminderTests.swift
//  kebabTests
//
//  Reminders are a promise: "bring this back to me later." These tests pin
//  the parts of that promise that are easy to break silently — the date
//  math behind the presets, Random's hidden instant (generated once, never
//  re-rolled, never rendered), the one-reminder-per-entry constraint, the
//  scheduled → fired → opened lifecycle, and the cleanup paths that would
//  otherwise leave ghost deliveries behind.
//

import Foundation
import Testing
@testable import kebab

// MARK: - Test doubles

/// In-memory stand-in for the `entry_reminders` table.
final class FakeReminderRepository: ReminderSyncing, @unchecked Sendable {
    var rows: [UUID: EntryReminder] = [:]
    var isOffline = false
    private(set) var upsertCount = 0
    private(set) var deletedIds: [UUID] = []

    struct Offline: Error {}

    func fetchAll() async throws -> [EntryReminder] {
        if isOffline { throw Offline() }
        return Array(rows.values)
    }

    func upsert(_ reminder: EntryReminder) async throws {
        if isOffline { throw Offline() }
        upsertCount += 1
        rows[reminder.entryId] = reminder
    }

    func delete(entryId: UUID) async throws {
        if isOffline { throw Offline() }
        deletedIds.append(entryId)
        rows[entryId] = nil
    }
}

/// Stand-in for the notification centre. Keyed by entry id, which is how
/// the real scheduler enforces "one request per entry".
final class FakeReminderScheduler: ReminderScheduling, @unchecked Sendable {
    var status: ReminderAuthorization = .authorized
    /// What a contextual permission prompt would answer.
    var requestOutcome: ReminderAuthorization = .authorized
    private(set) var requestCount = 0
    private(set) var scheduled: [UUID: ReminderNotificationRequest] = [:]
    private(set) var cancelledIds: [UUID] = []

    func authorizationStatus() async -> ReminderAuthorization { status }

    func requestAuthorization() async -> ReminderAuthorization {
        requestCount += 1
        status = requestOutcome
        return requestOutcome
    }

    func schedule(_ request: ReminderNotificationRequest) async {
        scheduled[request.entryId] = request
    }

    func cancel(entryIds: [UUID]) async {
        cancelledIds.append(contentsOf: entryIds)
        for id in entryIds { scheduled[id] = nil }
    }

    func cancelAll() async {
        cancelledIds.append(contentsOf: scheduled.keys)
        scheduled.removeAll()
    }

    func pendingEntryIds() async -> Set<UUID> { Set(scheduled.keys) }
}

/// Disk stand-in. Survives across `ReminderStore` instances in a test, which
/// is exactly what "relaunch" means here.
final class InMemoryReminderPersistence: ReminderPersisting {
    var storage: [String: ReminderMirror] = [:]
    func load(key: String) -> ReminderMirror? { storage[key] }
    func save(_ mirror: ReminderMirror, key: String) { storage[key] = mirror }
}

/// Movable clock: lets a test walk a reminder past its fire time without
/// waiting for it.
final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
struct ReminderTests {

    private static let user = UUID()

    /// A fixed, unambiguous instant to reason from: 2026-03-10 08:00 local.
    nonisolated private static func baseDate(hour: Int = 8, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 10
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.current.date(from: components)!
    }

    private static func entry(
        id: UUID = UUID(),
        content: String = "Could Bitcoin mining become the buyer of last resort for stranded nuclear capacity?",
        attachments: [EntryAttachment]? = nil,
        hidden: Bool = false
    ) -> Entry {
        Entry(
            id: id,
            user_id: user,
            parent_id: nil,
            root_id: id,
            depth: 0,
            content: content,
            created_at: Date(timeIntervalSince1970: 1_000_000),
            pinned_at: nil,
            isContentHidden: hidden,
            comment_count: nil,
            resurface_count: 0,
            fire_count: 0,
            attachments: attachments,
            collection_id: nil,
            collection_name: nil,
            collection_parent_id: nil,
            collection_parent_name: nil
        )
    }

    private struct Harness {
        let store: ReminderStore
        let repository: FakeReminderRepository
        let scheduler: FakeReminderScheduler
        let persistence: InMemoryReminderPersistence
        let clock: TestClock
    }

    private static func makeHarness(
        now: Date? = nil,
        persistence: InMemoryReminderPersistence = InMemoryReminderPersistence(),
        repository: FakeReminderRepository = FakeReminderRepository(),
        scheduler: FakeReminderScheduler = FakeReminderScheduler()
    ) -> Harness {
        let now = now ?? baseDate()
        let clock = TestClock(now)
        let store = ReminderStore(
            repository: repository,
            scheduler: scheduler,
            persistence: persistence,
            now: { clock.now }
        )
        store.configure(userId: user)
        return Harness(
            store: store,
            repository: repository,
            scheduler: scheduler,
            persistence: persistence,
            clock: clock
        )
    }

    /// Lets fire-and-forget work (server pushes, cancellations) finish.
    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - Presets

    @Test
    func laterTodayLandsAFewHoursOutOnTheSameDay() {
        let now = Self.baseDate(hour: 8, minute: 7)
        let result = ReminderSchedule.laterToday(from: now)
        let calendar = Calendar.current
        #expect(calendar.isDate(result, inSameDayAs: now))
        #expect(result > now)
        // ~3 hours out, rounded up to a clean quarter hour.
        #expect(calendar.component(.hour, from: result) == 11)
        #expect(calendar.component(.minute, from: result) % 15 == 0)
    }

    @Test
    func laterTodayCapsAtTheEveningRatherThanSchedulingAfterMidnight() {
        let now = Self.baseDate(hour: 20, minute: 0)
        let result = ReminderSchedule.laterToday(from: now)
        let calendar = Calendar.current
        #expect(calendar.isDate(result, inSameDayAs: now))
        #expect(calendar.component(.hour, from: result) == ReminderSchedule.laterTodayCapHour)
        #expect(result > now)
    }

    @Test
    func laterTodayLateAtNightBecomesTomorrowMorning() {
        let now = Self.baseDate(hour: 23, minute: 30)
        let result = ReminderSchedule.laterToday(from: now)
        let calendar = Calendar.current
        #expect(!calendar.isDate(result, inSameDayAs: now))
        #expect(calendar.component(.hour, from: result) == ReminderSchedule.morningHour)
        #expect(result > now)
    }

    @Test
    func tomorrowIsNineInTheMorningTheNextDay() {
        let now = Self.baseDate(hour: 14, minute: 22)
        let result = ReminderSchedule.tomorrowMorning(from: now)
        let calendar = Calendar.current
        let daysApart = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: result)
        ).day
        #expect(daysApart == 1)
        #expect(calendar.component(.hour, from: result) == 9)
        #expect(calendar.component(.minute, from: result) == 0)
    }

    @Test
    func inAWeekKeepsTheSameWallClockTimeSevenDaysOut() {
        let now = Self.baseDate(hour: 14, minute: 22)
        let result = ReminderSchedule.inAWeek(from: now)
        let calendar = Calendar.current
        #expect(calendar.dateComponents([.day], from: now, to: result).day == 7)
        #expect(calendar.component(.hour, from: result) == 14)
        #expect(calendar.component(.minute, from: result) == 22)
    }

    @Test
    func pickADateOpensOnASaneFutureDefault() {
        let now = Self.baseDate(hour: 23, minute: 59)
        let result = ReminderSchedule.pickADateDefault(from: now)
        #expect(result > now)
        #expect(Calendar.current.component(.hour, from: result) == 9)
    }

    @Test
    func everyPresetPrefillIsInTheFuture() {
        for hour in 0...23 {
            let now = Self.baseDate(hour: hour, minute: 31)
            for preset in ReminderPreset.allCases {
                let prefill = ReminderSchedule.prefill(for: preset, from: now)
                #expect(prefill > now, "\(preset) at hour \(hour) prefilled into the past")
            }
        }
    }

    // MARK: - Random generation

    @Test
    func randomAlwaysLandsInsideThirtyDaysAndWakingHours() {
        var generator = SystemRandomNumberGenerator()
        for hour in 0...23 {
            let now = Self.baseDate(hour: hour, minute: 45)
            for _ in 0..<60 {
                let fireAt = ReminderSchedule.randomFireDate(from: now, using: &generator)
                #expect(
                    ReminderSchedule.isValidRandomFireDate(fireAt, from: now),
                    "generated \(fireAt) from \(now)"
                )
                #expect(fireAt >= now.addingTimeInterval(ReminderSchedule.minimumLead - 60))
            }
        }
    }

    @Test
    func randomIsSpreadAcrossTheWindowRatherThanPinnedToOneDay() {
        var generator = SystemRandomNumberGenerator()
        let now = Self.baseDate(hour: 8)
        var days = Set<Int>()
        var hours = Set<Int>()
        for _ in 0..<200 {
            let fireAt = ReminderSchedule.randomFireDate(from: now, using: &generator)
            days.insert(Calendar.current.dateComponents([.day], from: now, to: fireAt).day ?? -1)
            hours.insert(Calendar.current.component(.hour, from: fireAt))
        }
        // Uniform, not clever — but it must genuinely use the window.
        #expect(days.count > 10)
        #expect(hours.count > 5)
    }

    @Test
    func randomInstantIsNeverRenderedAnywhereInTheUI() {
        let now = Self.baseDate(hour: 8)
        let fireAt = ReminderSchedule.randomFireDate(from: now)
        let reminder = EntryReminder(
            entryId: UUID(), userId: Self.user, fireAt: fireAt, mode: .random, note: nil
        )
        let label = ReminderDisplay.affordanceLabel(for: reminder, canDeliver: true, now: now)
        #expect(label == "Random")
        // No digits at all: no date, no time, no countdown, no narrower range.
        let hasDigits = label.rangeOfCharacter(from: .decimalDigits) != nil
        #expect(!hasDigits)
        #expect(!ReminderDisplay.randomPromise.contains(ReminderDisplay.time(for: fireAt)))
        #expect(ReminderDisplay.randomPromise.contains("30 days"))
    }

    @Test
    func scheduledAffordanceReadsAsHumanTime() {
        let now = Self.baseDate(hour: 8)
        let fireAt = ReminderSchedule.tomorrowMorning(from: now)
        let reminder = EntryReminder(
            entryId: UUID(), userId: Self.user, fireAt: fireAt, mode: .scheduled, note: nil
        )
        let label = ReminderDisplay.affordanceLabel(for: reminder, canDeliver: true, now: now)
        #expect(label.hasPrefix("Tomorrow, "))
    }

    @Test
    func affordanceTellsTheTruthWhenTheOSWillNotDeliver() {
        let now = Self.baseDate(hour: 8)
        let reminder = EntryReminder(
            entryId: UUID(),
            userId: Self.user,
            fireAt: ReminderSchedule.tomorrowMorning(from: now),
            mode: .scheduled,
            note: nil
        )
        #expect(
            ReminderDisplay.affordanceLabel(for: reminder, canDeliver: false, now: now)
                == "Reminders off"
        )
    }

    @Test
    func randomIsRegeneratedOnlyWhenTheUserPicksRandomAgain() {
        let existing = Self.baseDate(hour: 12)
        let regenerated = Self.baseDate(hour: 18)
        var generateCount = 0
        let generate: () -> Date = {
            generateCount += 1
            return Self.baseDate(hour: 20)
        }

        // Opening the editor / editing only the note: preserved verbatim.
        #expect(
            ReminderEditing.randomFireAt(regenerated: nil, existing: existing, generate: generate)
                == existing
        )
        // Explicitly re-picking Random: the fresh instant wins.
        #expect(
            ReminderEditing.randomFireAt(
                regenerated: regenerated, existing: existing, generate: generate
            ) == regenerated
        )
        #expect(generateCount == 0)
        // Brand new Random reminder: generated once.
        _ = ReminderEditing.randomFireAt(regenerated: nil, existing: nil, generate: generate)
        #expect(generateCount == 1)
    }

    // MARK: - Sheet flow

    @Test
    func creationStartsAtTheChoicesAndRunsForward() {
        #expect(ReminderFlowStep.entryStep(editing: nil) == .choosing)
        #expect(ReminderFlowStep.choosing.back(mode: .scheduled) == nil)
        #expect(ReminderFlowStep.timing.back(mode: .scheduled) == .choosing)
        #expect(ReminderFlowStep.note.back(mode: .scheduled) == .timing)
    }

    @Test
    func editingOpensOnWhatKebabAlreadyKnows() {
        // No re-answering the preset question: a scheduled reminder opens on
        // its timing, a Random one on its promise.
        #expect(ReminderFlowStep.entryStep(editing: .scheduled) == .timing)
        #expect(ReminderFlowStep.entryStep(editing: .random) == .randomConfirmation)
    }

    @Test
    func randomWalksTheSameRhythmWithoutTheTimingStep() {
        #expect(ReminderFlowStep.randomConfirmation.back(mode: .random) == .choosing)
        // Back from the note returns to the promise, never to date/time.
        #expect(ReminderFlowStep.note.back(mode: .random) == .randomConfirmation)
    }

    // MARK: - Creating

    @Test
    func creatingAScheduledReminderPersistsSchedulesAndSyncs() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        let fireAt = ReminderSchedule.tomorrowMorning(from: harness.clock.now)

        let outcome = await harness.store.save(
            entry: entry, mode: .scheduled, fireAt: fireAt, note: nil
        )

        guard case .saved(let reminder) = outcome else {
            Issue.record("expected a saved reminder, got \(outcome)")
            return
        }
        #expect(reminder.fireAt == fireAt)
        #expect(reminder.mode == .scheduled)
        #expect(harness.store.reminder(for: entry.id)?.fireAt == fireAt)
        #expect(harness.scheduler.scheduled[entry.id]?.fireAt == fireAt)
        #expect(harness.scheduler.scheduled[entry.id]?.title == "You wanted this back")
        #expect(harness.repository.rows[entry.id]?.fireAt == fireAt)
        #expect(harness.store.lifecycle(for: entry.id) == .scheduled)
    }

    @Test
    func optionalNotePersistsAndBecomesTheNotificationBody() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        let note = "See if this still feels true after earnings."

        _ = await harness.store.save(
            entry: entry,
            mode: .scheduled,
            fireAt: ReminderSchedule.tomorrowMorning(from: harness.clock.now),
            note: note
        )

        #expect(harness.store.reminder(for: entry.id)?.note == note)
        #expect(harness.scheduler.scheduled[entry.id]?.body == note)
        #expect(harness.repository.rows[entry.id]?.note == note)
    }

    @Test
    func skippingTheNoteLeavesAnEntryExcerptInstead() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()

        _ = await harness.store.save(
            entry: entry,
            mode: .scheduled,
            fireAt: ReminderSchedule.tomorrowMorning(from: harness.clock.now),
            note: "   "
        )

        #expect(harness.store.reminder(for: entry.id)?.note == nil)
        let body = harness.scheduler.scheduled[entry.id]?.body ?? ""
        #expect(body.hasPrefix("Could Bitcoin mining"))
        #expect(body.count <= 121)
    }

    @Test
    func creatingARandomReminderHidesItsInstantButStillSchedulesIt() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        let fireAt = ReminderSchedule.randomFireDate(from: harness.clock.now)

        _ = await harness.store.save(entry: entry, mode: .random, fireAt: fireAt, note: nil)

        let stored = harness.store.reminder(for: entry.id)
        #expect(stored?.mode == .random)
        #expect(stored?.fireAt == fireAt)
        #expect(harness.scheduler.scheduled[entry.id]?.fireAt == fireAt)
        #expect(
            ReminderDisplay.affordanceLabel(
                for: stored!, canDeliver: true, now: harness.clock.now
            ) == "Random"
        )
    }

    @Test
    func onlyOneReminderCanExistPerEntry() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        let first = ReminderSchedule.tomorrowMorning(from: harness.clock.now)
        let second = ReminderSchedule.inAWeek(from: harness.clock.now)

        _ = await harness.store.save(entry: entry, mode: .scheduled, fireAt: first, note: "first")
        _ = await harness.store.save(entry: entry, mode: .scheduled, fireAt: second, note: "second")

        #expect(harness.store.reminder(for: entry.id)?.fireAt == second)
        #expect(harness.store.reminder(for: entry.id)?.note == "second")
        // One record, one pending request — never a second delivery.
        #expect(harness.repository.rows.count == 1)
        #expect(harness.scheduler.scheduled.count == 1)
        #expect(harness.scheduler.scheduled[entry.id]?.fireAt == second)
    }

    // MARK: - Editing

    @Test
    func editingAnExistingReminderKeepsItsIdentityAndReplacesItsTiming() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        _ = await harness.store.save(
            entry: entry,
            mode: .scheduled,
            fireAt: ReminderSchedule.tomorrowMorning(from: harness.clock.now),
            note: "first thought"
        )
        let createdAt = harness.store.reminder(for: entry.id)?.createdAt

        let newFireAt = ReminderSchedule.inAWeek(from: harness.clock.now)
        _ = await harness.store.save(
            entry: entry, mode: .scheduled, fireAt: newFireAt, note: "second thought"
        )

        let updated = harness.store.reminder(for: entry.id)
        #expect(updated?.createdAt == createdAt)
        #expect(updated?.fireAt == newFireAt)
        #expect(updated?.note == "second thought")
    }

    @Test
    func switchingRandomToScheduledAndBackBehavesAsTwoDistinctModes() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        let randomFireAt = ReminderSchedule.randomFireDate(from: harness.clock.now)

        _ = await harness.store.save(entry: entry, mode: .random, fireAt: randomFireAt, note: nil)
        #expect(harness.store.reminder(for: entry.id)?.mode == .random)

        let scheduledFireAt = ReminderSchedule.tomorrowMorning(from: harness.clock.now)
        _ = await harness.store.save(
            entry: entry, mode: .scheduled, fireAt: scheduledFireAt, note: nil
        )
        #expect(harness.store.reminder(for: entry.id)?.mode == .scheduled)
        #expect(harness.store.reminder(for: entry.id)?.fireAt == scheduledFireAt)

        let secondRandom = ReminderSchedule.randomFireDate(from: harness.clock.now)
        _ = await harness.store.save(entry: entry, mode: .random, fireAt: secondRandom, note: nil)
        #expect(harness.store.reminder(for: entry.id)?.mode == .random)
        #expect(harness.store.reminder(for: entry.id)?.fireAt == secondRandom)
        #expect(harness.scheduler.scheduled.count == 1)
    }

    @Test
    func removingAReminderCancelsDeliveryAndClearsEveryTrace() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        _ = await harness.store.save(
            entry: entry,
            mode: .scheduled,
            fireAt: ReminderSchedule.tomorrowMorning(from: harness.clock.now),
            note: "note"
        )

        await harness.store.removeReminder(entryId: entry.id)

        #expect(harness.store.reminder(for: entry.id) == nil)
        #expect(harness.scheduler.scheduled[entry.id] == nil)
        #expect(harness.scheduler.cancelledIds.contains(entry.id))
        #expect(harness.repository.rows[entry.id] == nil)
        #expect(harness.repository.deletedIds.contains(entry.id))
        #expect(harness.store.pendingNote(for: entry.id) == nil)
    }

    // MARK: - Lifecycle

    @Test
    func scheduledBecomesFiredUnreadOnceItsTimePasses() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        let fireAt = harness.clock.now.addingTimeInterval(3600)
        _ = await harness.store.save(entry: entry, mode: .scheduled, fireAt: fireAt, note: nil)
        #expect(harness.store.lifecycle(for: entry.id) == .scheduled)
        #expect(harness.store.activeReminder(for: entry.id) != nil)

        harness.clock.now = fireAt.addingTimeInterval(60)

        #expect(harness.store.lifecycle(for: entry.id) == .firedUnread)
        // A fired reminder no longer counts as active: "Remind me" starts a
        // fresh one instead of reopening a finished schedule.
        #expect(harness.store.activeReminder(for: entry.id) == nil)
    }

    @Test
    func openingAFiredEntryClearsItsUnreadState() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        let fireAt = harness.clock.now.addingTimeInterval(3600)
        _ = await harness.store.save(entry: entry, mode: .scheduled, fireAt: fireAt, note: nil)
        harness.clock.now = fireAt.addingTimeInterval(60)

        harness.store.markOpened(entryId: entry.id)

        #expect(harness.store.lifecycle(for: entry.id) == .opened)
    }

    @Test
    func openingBeforeDeliveryNeverConsumesTheReminder() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        _ = await harness.store.save(
            entry: entry,
            mode: .scheduled,
            fireAt: harness.clock.now.addingTimeInterval(3600),
            note: nil
        )

        harness.store.markOpened(entryId: entry.id)

        #expect(harness.store.lifecycle(for: entry.id) == .scheduled)
        #expect(harness.store.reminder(for: entry.id)?.acknowledgedAt == nil)
    }

    @Test
    func theNoteSurvivesDeliveryAndOpeningUntilItIsDismissed() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        let fireAt = harness.clock.now.addingTimeInterval(3600)
        _ = await harness.store.save(
            entry: entry, mode: .scheduled, fireAt: fireAt, note: "See if this still feels true."
        )

        // Not delivered yet: no banner.
        #expect(harness.store.pendingNote(for: entry.id) == nil)

        harness.clock.now = fireAt.addingTimeInterval(60)
        #expect(harness.store.pendingNote(for: entry.id) == "See if this still feels true.")

        harness.store.markOpened(entryId: entry.id)
        // Opening ends unread — it does NOT take the note away.
        #expect(harness.store.pendingNote(for: entry.id) == "See if this still feels true.")

        harness.store.dismissNote(entryId: entry.id)
        #expect(harness.store.pendingNote(for: entry.id) == nil)
        #expect(harness.store.reminder(for: entry.id)?.note == "See if this still feels true.")
    }

    @Test
    func aReminderWithoutANoteLeavesNoBannerBehind() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        let fireAt = harness.clock.now.addingTimeInterval(3600)
        _ = await harness.store.save(entry: entry, mode: .scheduled, fireAt: fireAt, note: nil)
        harness.clock.now = fireAt.addingTimeInterval(60)

        #expect(harness.store.pendingNote(for: entry.id) == nil)
    }

    @Test
    func aMissedReminderKeepsItsUnreadStateForDays() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        let fireAt = harness.clock.now.addingTimeInterval(3600)
        _ = await harness.store.save(entry: entry, mode: .scheduled, fireAt: fireAt, note: "later")

        // Fires Tuesday, ignored; the user opens Kebab on Thursday.
        harness.clock.now = fireAt.addingTimeInterval(2 * 86_400)
        await harness.store.refresh()

        #expect(harness.store.lifecycle(for: entry.id) == .firedUnread)
        #expect(harness.store.pendingNote(for: entry.id) == "later")
        // Nothing pending is left scheduled for it.
        let stillPending = await harness.scheduler.pendingEntryIds()
        #expect(!stillPending.contains(entry.id))
    }

    // MARK: - Persistence

    @Test
    func remindersSurviveRelaunch() async {
        let persistence = InMemoryReminderPersistence()
        let firstLaunch = Self.makeHarness(persistence: persistence)
        let entry = Self.entry()
        let fireAt = ReminderSchedule.randomFireDate(from: firstLaunch.clock.now)
        _ = await firstLaunch.store.save(entry: entry, mode: .random, fireAt: fireAt, note: "why")

        // Cold start: same disk, empty scheduler, fresh store.
        let relaunch = Self.makeHarness(
            persistence: persistence,
            repository: FakeReminderRepository(),
            scheduler: FakeReminderScheduler()
        )

        let restored = relaunch.store.reminder(for: entry.id)
        #expect(restored?.fireAt == fireAt, "a Random instant must never change across launches")
        #expect(restored?.mode == .random)
        #expect(restored?.note == "why")
    }

    @Test
    func relaunchReschedulesDeliveryFromTheRecord() async {
        let persistence = InMemoryReminderPersistence()
        let repository = FakeReminderRepository()
        let first = Self.makeHarness(persistence: persistence, repository: repository)
        let entry = Self.entry()
        let fireAt = first.clock.now.addingTimeInterval(4 * 86_400)
        _ = await first.store.save(entry: entry, mode: .scheduled, fireAt: fireAt, note: nil)

        // A relaunch (or device restart) where the notification queue is empty.
        let scheduler = FakeReminderScheduler()
        let second = Self.makeHarness(
            persistence: persistence, repository: repository, scheduler: scheduler
        )
        await second.store.refresh()

        #expect(scheduler.scheduled[entry.id]?.fireAt == fireAt)
        // The Random rule's cousin: reconciliation reschedules, never re-times.
        #expect(second.store.reminder(for: entry.id)?.fireAt == fireAt)
    }

    @Test
    func offlineWritesStayQueuedAndTheMirrorStaysAuthoritative() async {
        let repository = FakeReminderRepository()
        repository.isOffline = true
        let harness = Self.makeHarness(repository: repository)
        let entry = Self.entry()
        let fireAt = ReminderSchedule.tomorrowMorning(from: harness.clock.now)

        _ = await harness.store.save(entry: entry, mode: .scheduled, fireAt: fireAt, note: "n")
        // Local truth is complete even though the server never heard about it.
        #expect(harness.store.reminder(for: entry.id)?.fireAt == fireAt)
        #expect(repository.rows.isEmpty)

        repository.isOffline = false
        await harness.store.refresh()

        #expect(repository.rows[entry.id]?.fireAt == fireAt)
        #expect(harness.store.reminder(for: entry.id)?.fireAt == fireAt)
    }

    @Test
    func serverRecordsFromAnotherDeviceAreAdoptedAndScheduled() async {
        let repository = FakeReminderRepository()
        let entryId = UUID()
        let harness = Self.makeHarness(repository: repository)
        let fireAt = harness.clock.now.addingTimeInterval(2 * 86_400)
        repository.rows[entryId] = EntryReminder(
            entryId: entryId, userId: Self.user, fireAt: fireAt, mode: .scheduled, note: "remote"
        )

        await harness.store.refresh()

        #expect(harness.store.reminder(for: entryId)?.note == "remote")
        #expect(harness.scheduler.scheduled[entryId]?.fireAt == fireAt)
    }

    // MARK: - Cleanup

    @Test
    func deletingAnEntryCancelsAndPurgesItsReminder() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        _ = await harness.store.save(
            entry: entry,
            mode: .scheduled,
            fireAt: ReminderSchedule.tomorrowMorning(from: harness.clock.now),
            note: "note"
        )

        harness.store.handleEntryDeleted(id: entry.id)
        await Self.settle()

        #expect(harness.store.reminder(for: entry.id) == nil)
        #expect(harness.store.pendingNote(for: entry.id) == nil)
        #expect(harness.scheduler.scheduled[entry.id] == nil)
        #expect(harness.scheduler.cancelledIds.contains(entry.id))
    }

    @Test
    func refreshCancelsOrphanedDeliveries() async {
        let harness = Self.makeHarness()
        let orphanId = UUID()
        await harness.scheduler.schedule(
            ReminderNotificationRequest(
                entryId: orphanId,
                fireAt: harness.clock.now.addingTimeInterval(86_400),
                title: "You wanted this back",
                body: "ghost"
            )
        )

        await harness.store.refresh()

        #expect(harness.scheduler.scheduled[orphanId] == nil)
        #expect(harness.scheduler.cancelledIds.contains(orphanId))
    }

    // MARK: - Permission

    @Test
    func aDeniedPermissionNeverPretendsTheReminderIsActive() async {
        let scheduler = FakeReminderScheduler()
        scheduler.status = .notDetermined
        scheduler.requestOutcome = .denied
        let harness = Self.makeHarness(scheduler: scheduler)
        let entry = Self.entry()

        let outcome = await harness.store.save(
            entry: entry,
            mode: .scheduled,
            fireAt: ReminderSchedule.tomorrowMorning(from: harness.clock.now),
            note: "n"
        )

        #expect(outcome == .permissionDenied)
        #expect(harness.store.reminder(for: entry.id) == nil)
        #expect(harness.scheduler.scheduled.isEmpty)
        #expect(harness.repository.rows.isEmpty)
        #expect(harness.store.authorization == .denied)
    }

    @Test
    func permissionIsOnlyRequestedWhenTheUserActuallySetsAReminder() async {
        let scheduler = FakeReminderScheduler()
        scheduler.status = .notDetermined
        let harness = Self.makeHarness(scheduler: scheduler)
        await harness.store.refresh()
        #expect(scheduler.requestCount == 0)

        _ = await harness.store.save(
            entry: Self.entry(),
            mode: .scheduled,
            fireAt: ReminderSchedule.tomorrowMorning(from: harness.clock.now),
            note: nil
        )
        #expect(scheduler.requestCount == 1)
    }

    @Test
    func permissionRevokedAfterCreationIsReflectedNotHidden() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        _ = await harness.store.save(
            entry: entry,
            mode: .scheduled,
            fireAt: ReminderSchedule.tomorrowMorning(from: harness.clock.now),
            note: nil
        )

        harness.scheduler.status = .denied
        await harness.store.refresh()

        #expect(harness.store.authorization == .denied)
        // The record survives — but the UI says reminders are off.
        let reminder = harness.store.reminder(for: entry.id)
        #expect(reminder != nil)
        #expect(
            ReminderDisplay.affordanceLabel(
                for: reminder!,
                canDeliver: harness.store.authorization.canDeliver,
                now: harness.clock.now
            ) == "Reminders off"
        )
    }

    // MARK: - Delivery routing

    @Test
    func tappingANotificationDeepLinksToThatExactEntry() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        _ = await harness.store.save(
            entry: entry,
            mode: .scheduled,
            fireAt: harness.clock.now.addingTimeInterval(60),
            note: nil
        )

        harness.store.handleReminderTap(entryId: entry.id)

        #expect(harness.store.deepLinkEntryId == entry.id)
    }

    @Test
    func aTapThatArrivesBeforeTheStoreExistsIsReplayed() async {
        // A private bridge instance: the app uses the shared one, but the
        // behavior under test is buffer-then-replay, not global state.
        let bridge = ReminderNotificationBridge()
        let entryId = UUID()
        // Cold launch: the response lands before any SwiftUI state is alive.
        bridge.receiveTap(entryId: entryId)

        let harness = Self.makeHarness()
        bridge.attach(harness.store)

        #expect(harness.store.deepLinkEntryId == entryId)
    }

    @Test
    func firingWhileElsewhereInKebabRaisesTheInAppBanner() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        _ = await harness.store.save(
            entry: entry,
            mode: .scheduled,
            fireAt: harness.clock.now.addingTimeInterval(60),
            note: "check this"
        )
        harness.store.currentlyViewedEntryId = UUID()   // somewhere else

        let handled = harness.store.handleForegroundDelivery(entryId: entry.id)

        #expect(handled)  // Kebab presents it, not the system
        #expect(harness.store.foregroundDelivery?.entryId == entry.id)
        #expect(harness.store.foregroundDelivery?.body == "check this")
    }

    @Test
    func firingWhileAlreadyViewingTheEntryDoesNotInterrupt() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        let fireAt = harness.clock.now.addingTimeInterval(60)
        _ = await harness.store.save(
            entry: entry, mode: .scheduled, fireAt: fireAt, note: "the note"
        )
        harness.store.currentlyViewedEntryId = entry.id
        harness.clock.now = fireAt.addingTimeInterval(1)

        let handled = harness.store.handleForegroundDelivery(entryId: entry.id)

        #expect(handled)
        #expect(harness.store.foregroundDelivery == nil)
        // Already where the reminder wanted them: unread never begins,
        // but the note context is still revealed.
        #expect(harness.store.lifecycle(for: entry.id) == .opened)
        #expect(harness.store.pendingNote(for: entry.id) == "the note")
    }

    @Test
    func deliveryForARemovedReminderIsSwallowed() async {
        let harness = Self.makeHarness()
        let entry = Self.entry()
        _ = await harness.store.save(
            entry: entry,
            mode: .scheduled,
            fireAt: harness.clock.now.addingTimeInterval(60),
            note: nil
        )
        await harness.store.removeReminder(entryId: entry.id)

        let handled = harness.store.handleForegroundDelivery(entryId: entry.id)

        #expect(handled)
        #expect(harness.store.foregroundDelivery == nil)
    }

    // MARK: - Notification copy

    @Test
    func theNotificationTitleIsTheSameForEveryReminderIncludingRandom() {
        #expect(ReminderNotificationContent.title == "You wanted this back")
    }

    @Test
    func theNotePreferredOverTheEntryExcerpt() {
        let entry = Self.entry()
        let note = "See if this still feels true after earnings."
        #expect(ReminderNotificationContent.body(for: entry, note: note) == note)
        #expect(ReminderNotificationContent.body(for: entry, note: "  ") != "  ")
    }

    @Test
    func excerptsHandleLinkImageAndChecklistEntries() {
        let link = Self.entry(
            content: "",
            attachments: [EntryAttachment(
                type: "link",
                url: "https://example.com/piece",
                title: "A very good piece",
                favicon_url: nil,
                image_url: nil
            )]
        )
        #expect(ReminderNotificationContent.excerpt(of: link) == "A very good piece")

        let image = Self.entry(
            content: "",
            attachments: [EntryAttachment(
                type: "image", url: "file:///a.jpg", title: nil, favicon_url: nil, image_url: nil
            )]
        )
        #expect(ReminderNotificationContent.excerpt(of: image) == "A photo you saved.")

        let checklist = Self.entry(content: "\(Checklist.uncheckedMarker) buy milk")
        #expect(ReminderNotificationContent.excerpt(of: checklist).contains("buy milk"))

        let hidden = Self.entry(hidden: true)
        #expect(ReminderNotificationContent.excerpt(of: hidden) == "A hidden entry.")
    }

    @Test
    func longExcerptsAreTruncatedRatherThanDumped() {
        let long = String(repeating: "thought ", count: 60)
        let entry = Self.entry(content: long)
        let excerpt = ReminderNotificationContent.excerpt(of: entry)
        #expect(excerpt.count < 130)
        #expect(excerpt.hasSuffix("\u{2026}"))
    }

    // MARK: - Blast radius

    @Test
    func reminderStateNeverTouchesFeedOrdering() async {
        let harness = Self.makeHarness()
        let entries = (0..<5).map { index in
            Entry(
                id: UUID(),
                user_id: Self.user,
                parent_id: nil,
                root_id: nil,
                depth: 0,
                content: "entry \(index)",
                created_at: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60),
                pinned_at: nil,
                isContentHidden: false,
                comment_count: nil,
                resurface_count: 0,
                fire_count: 0,
                attachments: nil,
                collection_id: nil,
                collection_name: nil,
                collection_parent_id: nil,
                collection_parent_name: nil
            )
        }
        let orderBefore = entries.map(\.id)

        // Reminders on some of them, one already fired.
        let fireAt = harness.clock.now.addingTimeInterval(60)
        _ = await harness.store.save(entry: entries[1], mode: .scheduled, fireAt: fireAt, note: nil)
        _ = await harness.store.save(
            entry: entries[3],
            mode: .random,
            fireAt: ReminderSchedule.randomFireDate(from: harness.clock.now),
            note: nil
        )
        harness.clock.now = fireAt.addingTimeInterval(1)
        _ = harness.store.handleForegroundDelivery(entryId: entries[1].id)

        // Reminder state is metadata beside the feed, never an input to it:
        // the entries themselves are untouched.
        #expect(entries.map(\.id) == orderBefore)
        #expect(harness.store.lifecycle(for: entries[1].id) == .firedUnread)
    }
}
