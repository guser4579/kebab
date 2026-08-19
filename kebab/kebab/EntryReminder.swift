//
//  EntryReminder.swift
//  kebab
//

import Foundation

/// How a reminder's delivery time was decided. `.random` is a first-class
/// mode, not a preset: Kebab picks the instant once and never shows it.
nonisolated enum ReminderMode: String, Codable, Sendable {
    case scheduled
    case random
}

/// The durable reminder record — one per entry, one shot, no recurrence.
///
/// The stored `fireAt` is the single source of truth for delivery AND for
/// lifecycle: the local notification is a delivery mechanism scheduled from
/// this record, never the record itself. For `.random` the instant is
/// generated exactly once (at creation) and is never rendered anywhere in
/// the UI — see `ReminderDisplay`.
nonisolated struct EntryReminder: Codable, Identifiable, Equatable, Sendable {

    let entryId: UUID
    let userId: UUID
    var fireAt: Date
    var mode: ReminderMode
    /// Optional context the user attached ("why I wanted this back").
    /// Never becomes a comment.
    var note: String?
    var createdAt: Date
    /// Set the first time the user revisits the entry after delivery —
    /// this is what ends the unread state.
    var acknowledgedAt: Date?
    /// Set when the user dismisses the delivered note banner.
    var noteDismissedAt: Date?

    var id: UUID { entryId }

    /// Longest note the composer (and the `entry_reminders` check
    /// constraint) accepts.
    static let noteCharacterLimit = 280

    enum CodingKeys: String, CodingKey {
        case entryId = "entry_id"
        case userId = "user_id"
        case fireAt = "fire_at"
        case mode
        case note
        case createdAt = "created_at"
        case acknowledgedAt = "acknowledged_at"
        case noteDismissedAt = "note_dismissed_at"
    }

    init(
        entryId: UUID,
        userId: UUID,
        fireAt: Date,
        mode: ReminderMode,
        note: String?,
        createdAt: Date = Date(),
        acknowledgedAt: Date? = nil,
        noteDismissedAt: Date? = nil
    ) {
        self.entryId = entryId
        self.userId = userId
        self.fireAt = fireAt
        self.mode = mode
        self.note = note
        self.createdAt = createdAt
        self.acknowledgedAt = acknowledgedAt
        self.noteDismissedAt = noteDismissedAt
    }
}

extension EntryReminder {

    /// The three states a reminder can be in. Scheduling ends when the
    /// reminder fires; unread ends when the user revisits the entry.
    enum Lifecycle: Equatable {
        /// Not yet delivered — shows the clock affordance.
        case scheduled
        /// Delivered but the entry hasn't been revisited — shows the quiet
        /// unread treatment in the feed, never a pending clock.
        case firedUnread
        /// Revisited. No scheduling UI remains; only a note banner may.
        case opened
    }

    func lifecycle(now: Date = Date()) -> Lifecycle {
        if fireAt > now { return .scheduled }
        return acknowledgedAt == nil ? .firedUnread : .opened
    }

    /// True while the reminder still owes the user a delivery. The entry
    /// points reopen an active reminder instead of starting a new one; a
    /// fired reminder is finished scheduling, so it starts a fresh flow.
    func isActive(now: Date = Date()) -> Bool {
        fireAt > now
    }

    var trimmedNote: String? {
        guard let note else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The delivered note context still owed to the user: it survives until
    /// explicitly dismissed, whether or not the entry has been opened.
    func pendingNoteContext(now: Date = Date()) -> String? {
        guard fireAt <= now, noteDismissedAt == nil else { return nil }
        return trimmedNote
    }
}

// MARK: - Presets

/// The five shortcuts on the reminder sheet. The first four only pre-fill
/// the same date/time editor; Random is its own mode.
nonisolated enum ReminderPreset: String, CaseIterable, Identifiable, Sendable {
    case laterToday
    case tomorrow
    case inAWeek
    case pickADate
    case random

    var id: String { rawValue }

    var label: String {
        switch self {
        case .laterToday: return "Later today"
        case .tomorrow: return "Tomorrow"
        case .inAWeek: return "In a week"
        case .pickADate: return "Pick a date"
        case .random: return "Random"
        }
    }
}

// MARK: - Date math

/// Every date decision a reminder makes, in one pure place: preset
/// pre-fills and Random generation. Deliberately calendar-driven (never
/// raw arithmetic on seconds) so DST transitions, month ends, and locale
/// all fall out of the platform.
nonisolated enum ReminderSchedule {

    /// Random delivery lands somewhere in the next 30 days …
    static let randomWindowDays = 30
    /// … during waking hours: 9:00 AM through 8:00 PM, local.
    static let randomOpeningHour = 9
    static let randomClosingHour = 20
    /// Nothing is ever scheduled closer than this to now — a "random"
    /// reminder that fires the same minute you set it isn't a surprise.
    static let minimumLead: TimeInterval = 30 * 60
    /// The morning hour every "tomorrow"-shaped default uses.
    static let morningHour = 9
    /// Latest a "Later today" default will reach before it gives up on today.
    static let laterTodayCapHour = 21

    /// A few hours out, rounded to a clean quarter hour, and never pushed
    /// into the small hours: past the evening cap it becomes 9:00 PM today,
    /// and once even that is gone it becomes tomorrow morning.
    static func laterToday(from now: Date, calendar: Calendar = .current) -> Date {
        let candidate = roundedUpToQuarterHour(now.addingTimeInterval(3 * 3600), calendar: calendar)
        let eveningCap = calendar.date(
            bySettingHour: laterTodayCapHour, minute: 0, second: 0, of: now
        )
        if calendar.isDate(candidate, inSameDayAs: now),
           let eveningCap, candidate <= eveningCap {
            return candidate
        }
        if let eveningCap, eveningCap > now.addingTimeInterval(minimumLead) {
            return eveningCap
        }
        return tomorrowMorning(from: now, calendar: calendar)
    }

    /// Tomorrow at 9:00 AM local.
    static func tomorrowMorning(from now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: tomorrow)
            ?? tomorrow
    }

    /// Exactly seven days out at the same wall-clock time (calendar
    /// addition, so a DST transition in between keeps the hour intact).
    static func inAWeek(from now: Date, calendar: Calendar = .current) -> Date {
        let sameTimeNextWeek = calendar.date(byAdding: .day, value: 7, to: now)
            ?? now.addingTimeInterval(7 * 86_400)
        return zeroingSeconds(sameTimeNextWeek, calendar: calendar)
    }

    /// The value "Pick a date" opens on — the editor emphasizes date
    /// selection, so the time only needs to be sane.
    static func pickADateDefault(from now: Date, calendar: Calendar = .current) -> Date {
        tomorrowMorning(from: now, calendar: calendar)
    }

    static func prefill(for preset: ReminderPreset, from now: Date, calendar: Calendar = .current) -> Date {
        switch preset {
        case .laterToday: return laterToday(from: now, calendar: calendar)
        case .tomorrow: return tomorrowMorning(from: now, calendar: calendar)
        case .inAWeek: return inAWeek(from: now, calendar: calendar)
        case .pickADate: return pickADateDefault(from: now, calendar: calendar)
        case .random: return tomorrowMorning(from: now, calendar: calendar)
        }
    }

    // MARK: Random

    /// One uniformly random instant across every valid delivery window in
    /// the next 30 days. "Valid" means: strictly in the future (with a
    /// minimum lead), and inside the 9:00 AM–8:00 PM local waking window of
    /// its day. Days are built through `Calendar`, so DST never slides the
    /// window off those hours.
    ///
    /// Deliberately uniform. No weighting, no behavior model — the magic is
    /// the unpredictability, not the algorithm.
    static func randomFireDate(
        from now: Date,
        calendar: Calendar = .current,
        using generator: inout some RandomNumberGenerator
    ) -> Date {
        let earliest = now.addingTimeInterval(minimumLead)
        let horizon = calendar.date(byAdding: .day, value: randomWindowDays, to: now)
            ?? now.addingTimeInterval(Double(randomWindowDays) * 86_400)

        var windows: [(start: Date, length: TimeInterval)] = []
        for dayOffset in 0...randomWindowDays {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now),
                  let opening = calendar.date(bySettingHour: randomOpeningHour, minute: 0, second: 0, of: day),
                  let closing = calendar.date(bySettingHour: randomClosingHour, minute: 0, second: 0, of: day)
            else { continue }
            let start = max(opening, earliest)
            let end = min(closing, horizon)
            let length = end.timeIntervalSince(start)
            if length > 0 {
                windows.append((start, length))
            }
        }

        guard !windows.isEmpty else {
            // Unreachable with a 30-day horizon, but never return the past.
            return tomorrowMorning(from: now, calendar: calendar)
        }

        let total = windows.reduce(0) { $0 + $1.length }
        var offset = Double.random(in: 0..<total, using: &generator)
        for window in windows {
            if offset < window.length {
                let picked = window.start.addingTimeInterval(offset)
                return zeroingSeconds(picked, calendar: calendar)
            }
            offset -= window.length
        }
        return zeroingSeconds(windows[windows.count - 1].start, calendar: calendar)
    }

    static func randomFireDate(from now: Date, calendar: Calendar = .current) -> Date {
        var generator = SystemRandomNumberGenerator()
        return randomFireDate(from: now, calendar: calendar, using: &generator)
    }

    /// The rule a generated Random instant must satisfy — used by the
    /// generator's tests and by nothing in the UI, which never sees it.
    static func isValidRandomFireDate(
        _ date: Date,
        from now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard date > now else { return false }
        guard let horizon = calendar.date(byAdding: .day, value: randomWindowDays, to: now),
              date <= horizon else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour else { return false }
        if hour < randomOpeningHour { return false }
        if hour > randomClosingHour { return false }
        if hour == randomClosingHour && (components.minute ?? 0) > 0 { return false }
        return true
    }

    // MARK: Helpers

    /// Guards against a user (or a stale sheet) committing a time that has
    /// already passed by the time they tap Set reminder.
    static func isInPast(_ date: Date, now: Date = Date()) -> Bool {
        date <= now
    }

    private static func roundedUpToQuarterHour(_ date: Date, calendar: Calendar) -> Date {
        let minute = calendar.component(.minute, from: date)
        let remainder = minute % 15
        let bumped = calendar.date(
            byAdding: .minute,
            value: remainder == 0 ? 0 : 15 - remainder,
            to: date
        ) ?? date
        return zeroingSeconds(bumped, calendar: calendar)
    }

    private static func zeroingSeconds(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(bySetting: .second, value: 0, of: date)
            ?? calendar.date(
                bySettingHour: calendar.component(.hour, from: date),
                minute: calendar.component(.minute, from: date),
                second: 0,
                of: date
            )
            ?? date
    }
}

/// The reminder sheet's steps, modelled outside the view so the sequence
/// (and where an edit enters it) can be pinned by tests.
///
/// Creation runs choices → timing → note. Editing skips the choices: Kebab
/// already knows the answer, so it opens on the step that shows it, with
/// Back still available for changing the decision itself.
nonisolated enum ReminderFlowStep: Equatable, Sendable {
    case choosing
    case timing
    case randomConfirmation
    case note

    static func entryStep(editing mode: ReminderMode?) -> ReminderFlowStep {
        switch mode {
        case .none: return .choosing
        case .some(.scheduled): return .timing
        case .some(.random): return .randomConfirmation
        }
    }

    /// The step Back returns to; nil on the selector, which has nothing
    /// behind it.
    func back(mode: ReminderMode) -> ReminderFlowStep? {
        switch self {
        case .choosing:
            return nil
        case .timing, .randomConfirmation:
            return .choosing
        case .note:
            return mode == .random ? .randomConfirmation : .timing
        }
    }
}

/// The one editing rule Random has, isolated so it can be pinned by a test:
/// a Random reminder's instant is regenerated ONLY when the user explicitly
/// picks Random again. Opening the editor, changing the note, or saving from
/// an existing Random reminder all preserve the instant already generated.
nonisolated enum ReminderEditing {
    static func randomFireAt(
        regenerated: Date?,
        existing: Date?,
        generate: () -> Date
    ) -> Date {
        regenerated ?? existing ?? generate()
    }
}

// MARK: - Presentation

/// Everything the UI is allowed to say about a reminder. The single gate
/// that keeps a Random reminder's generated instant off the screen: this
/// type never formats `fireAt` for a `.random` reminder.
nonisolated enum ReminderDisplay {

    /// The one line a Random reminder ever shows about its timing.
    static let randomPromise = "We\u{2019}ll bring this back sometime in the next 30 days."
    static let randomAffordanceLabel = "Random"
    /// Shown wherever the OS would prevent delivery.
    static let unavailableLabel = "Reminders off"

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Locale-driven: follows the device's 12/24-hour setting.
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static func dayFormatter(includeYear: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(includeYear ? "MMMdyyyy" : "MMMd")
        return formatter
    }

    static func time(for date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func day(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return dayFormatter(includeYear: !sameYear).string(from: date)
    }

    /// "Tomorrow, 9:00 AM" — the affordance's text for a scheduled reminder.
    static func dayAndTime(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        "\(day(for: date, now: now, calendar: calendar)), \(time(for: date))"
    }

    /// The affordance label for a reminder, honoring both the Random
    /// concealment rule and the OS permission reality.
    static func affordanceLabel(
        for reminder: EntryReminder,
        canDeliver: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard canDeliver else { return unavailableLabel }
        switch reminder.mode {
        case .random:
            return randomAffordanceLabel
        case .scheduled:
            return dayAndTime(for: reminder.fireAt, now: now, calendar: calendar)
        }
    }
}
