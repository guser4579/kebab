//
//  ReminderSheetView.swift
//  kebab
//

import SwiftUI

/// The reminder flow: one decision per sheet.
///
/// Choose when → confirm the timing (or read Random's promise) → optionally
/// say why. Each step shows only its own decision, a primary CTA, and a
/// quiet Back beneath it; the preset choices live on the first step alone,
/// so the later steps read as a sequence rather than a control panel.
///
/// Chrome matches the entry action sheet exactly — grabber, centered title,
/// hairline rows, drag-to-dismiss — and every step terminates the same way:
/// last interactive element, then the sheet's bottom inset. The sheet hugs
/// its content; there is no fixed height anywhere.
struct ReminderSheetView: View {

    let entry: Entry
    /// The reminder being edited, if any. Present means the flow opens at
    /// the step that reflects what Kebab already knows, and gains Remove.
    let existing: EntryReminder?
    let authorization: ReminderAuthorization
    /// Persist. Returns the outcome so a permission refusal can be shown
    /// in place instead of pretending the reminder is active.
    let onSet: (ReminderMode, Date, String?) async -> ReminderSaveOutcome
    let onRemove: () -> Void
    let onDismiss: () -> Void

    private enum Expanded {
        case date
        case time
    }

    @State private var step: ReminderFlowStep
    @State private var mode: ReminderMode
    @State private var fireAt: Date
    /// A Random reminder's instant, carried untouched through the flow.
    /// Regenerated only when the user explicitly picks Random again.
    @State private var randomFireAt: Date?
    @State private var note: String
    @State private var expanded: Expanded?
    @State private var isSaving = false
    /// Set after a save attempt the OS refused, so the sheet can tell the
    /// truth without lying about an active reminder.
    @State private var permissionRefused = false
    @State private var pastTimeWarning = false
    @FocusState private var isNoteFocused: Bool

    /// Same terminal inset the entry action sheet uses below its last
    /// control — the app's one bottom-sheet ending.
    private let sheetBottomInset: CGFloat = 32
    // Text-input metrics, matching the Account screen's name field.
    private static let fieldPaddingVertical: CGFloat = 12
    private static let fieldPaddingHorizontal: CGFloat = 16
    private static let fieldCornerRadius: CGFloat = 16

    init(
        entry: Entry,
        existing: EntryReminder?,
        authorization: ReminderAuthorization,
        onSet: @escaping (ReminderMode, Date, String?) async -> ReminderSaveOutcome,
        onRemove: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.entry = entry
        self.existing = existing
        self.authorization = authorization
        self.onSet = onSet
        self.onRemove = onRemove
        self.onDismiss = onDismiss
        _step = State(initialValue: ReminderFlowStep.entryStep(editing: existing?.mode))
        _mode = State(initialValue: existing?.mode ?? .scheduled)
        _fireAt = State(initialValue: existing?.fireAt ?? ReminderSchedule.tomorrowMorning(from: Date()))
        _randomFireAt = State(initialValue: existing?.mode == .random ? existing?.fireAt : nil)
        _note = State(initialValue: existing?.trimmedNote ?? "")
        _expanded = State(initialValue: nil)
    }

    private var isEditingExisting: Bool { existing != nil }

    private var remindersUnavailable: Bool {
        permissionRefused || authorization == .denied
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()
                .padding(.top, 12)
                .frame(maxWidth: .infinity)

            header
                .padding(.top, 20)

            switch step {
            case .choosing:
                choosingStep
            case .timing:
                timingStep
            case .randomConfirmation:
                randomStep
            case .note:
                noteStep
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .partialSheetSurface(onDismiss: onDismiss)
    }

    // MARK: - Header

    private var header: some View {
        Text(isEditingExisting ? "Reminder" : "Remind me")
            .font(.custom("DMSans-Medium", size: 16))
            .foregroundColor(Style.Color.primaryText)
            .lineLimit(1)
            .padding(.horizontal, 56)
            .frame(height: 24)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Step 1 · Choose when

    private var choosingStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Known-denied permission is worth saying before the user walks
            // the flow, not only at the end of it.
            if authorization == .denied {
                permissionBlock
                    .padding(.bottom, Style.Spacing.x2)
            }

            // One `now` for the whole list, so every row's label and the
            // decision about which rows exist agree with each other.
            let now = Date()

            ForEach(Array(ReminderPreset.available(at: now).enumerated()), id: \.element.id) { index, preset in
                if index > 0 { hairline }
                choiceRow(preset, now: now)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, sheetBottomInset)
    }

    private func choiceRow(_ preset: ReminderPreset, now: Date) -> some View {
        Button {
            select(preset)
        } label: {
            HStack(spacing: Style.Spacing.x3) {
                presetIcon(for: preset)
                    .foregroundColor(Style.Color.primaryText)
                    .frame(width: Style.Icon.grid, height: Style.Icon.grid)

                Text(preset.label)
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if preset != .random && preset != .pickADate,
                   let prefill = ReminderSchedule.prefill(for: preset, from: now) {
                    Text(ReminderDisplay.dayAndTime(for: prefill, now: now))
                        .font(Style.Typography.meta())
                        .foregroundColor(Style.Color.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Style.Layout.entryContentPadding)
            .padding(.vertical, Style.Spacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func presetIcon(for preset: ReminderPreset) -> some View {
        switch preset {
        case .laterToday:
            Image(systemName: "clock")
                .font(.system(size: 16, weight: .regular))
        case .tomorrow:
            Icon("sun-01")
        case .inAWeek:
            Icon("calendar-04")
        case .pickADate:
            Icon("date-time")
        case .random:
            Icon("dices")
        }
    }

    private func select(_ preset: ReminderPreset) {
        pastTimeWarning = false
        switch preset {
        case .random:
            mode = .random
            // Explicitly picking Random is the ONE thing that generates a
            // new instant. Navigating the flow never does.
            randomFireAt = ReminderSchedule.randomFireDate(from: Date())
            expanded = nil
            advance(to: .randomConfirmation)
        case .pickADate:
            mode = .scheduled
            fireAt = ReminderSchedule.pickADateDefault(from: Date())
            expanded = .date
            advance(to: .timing)
        case .laterToday, .tomorrow, .inAWeek:
            // A row that has no prefill is never rendered, so nil here can
            // only mean the clock crossed the cutoff between draw and tap:
            // leave the selector up rather than open the editor on a
            // meaningless time.
            guard let prefill = ReminderSchedule.prefill(for: preset, from: Date()) else { return }
            mode = .scheduled
            fireAt = prefill
            expanded = nil
            advance(to: .timing)
        }
    }

    // MARK: - Step 2 · Confirm the timing

    private var timingStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            valueRow(
                title: "Date",
                value: ReminderDisplay.day(for: fireAt),
                isOpen: expanded == .date
            ) {
                toggle(.date)
            }

            if expanded == .date {
                DatePicker(
                    "",
                    selection: $fireAt,
                    in: Date()...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(Style.Color.primaryText)
                .padding(.horizontal, Style.Spacing.x2)
            }

            hairline

            valueRow(
                title: "Time",
                value: ReminderDisplay.time(for: fireAt),
                isOpen: expanded == .time
            ) {
                toggle(.time)
            }

            if expanded == .time {
                // Native wheel mechanics (locale, 12/24-hour, accessibility)
                // inside Kebab's surface — familiar behavior, our language.
                DatePicker(
                    "",
                    selection: $fireAt,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            if pastTimeWarning {
                Text("That time has already passed \u{2014} pick a later one.")
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.destructive)
                    .padding(.horizontal, Style.Layout.entryContentPadding)
                    .padding(.top, Style.Spacing.x2)
            }

            actions(
                primaryTitle: "Next",
                primaryAction: advanceFromTiming,
                backAction: goBack
            )
        }
        .padding(.top, Style.Spacing.x2)
    }

    private func advanceFromTiming() {
        guard !ReminderSchedule.isInPast(fireAt) else {
            withAnimation(.easeOut(duration: 0.2)) { pastTimeWarning = true }
            return
        }
        pastTimeWarning = false
        expanded = nil
        advance(to: .note)
    }

    private func toggle(_ target: Expanded) {
        isNoteFocused = false
        withAnimation(.easeOut(duration: 0.2)) {
            expanded = expanded == target ? nil : target
        }
    }

    private func valueRow(
        title: String,
        value: String,
        isOpen: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Style.Spacing.x3) {
                Text(title)
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)

                Spacer(minLength: 0)

                Text(value)
                    .font(Style.Typography.body())
                    .foregroundColor(isOpen ? Style.Color.primaryText : Style.Color.secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Style.Color.secondary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, Style.Layout.entryContentPadding)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2 (Random) · The promise

    /// Random says exactly one thing about its timing — the 30-day promise.
    /// The generated instant is never rendered, never counted down, never
    /// narrowed.
    private var randomStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Icon("dices", glyphSize: 18, gridSize: 18)
                        .foregroundColor(Style.Color.primaryText)
                    Text(ReminderDisplay.randomAffordanceLabel)
                        .font(.custom("DMSans-Medium", size: 16))
                        .foregroundColor(Style.Color.primaryText)
                }

                Text(ReminderDisplay.randomPromise)
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.secondary)
                    .lineSpacing(Style.Typography.metaLineHeight - 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Style.Spacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Style.Color.composerBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Style.Color.separator, lineWidth: 1)
                    )
            )
            .padding(.horizontal, Style.Layout.entryContentPadding)

            actions(
                primaryTitle: "Next",
                primaryAction: { advance(to: .note) },
                backAction: goBack
            )
        }
        .padding(.top, Style.Spacing.x4)
    }

    // MARK: - Step 3 · Optional context

    private var noteStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Style.Spacing.x2) {
                // Kebab's standard text-input chrome, identical to the
                // Account screen's name field: composer surface, 16pt
                // corner, 12/16 insets, body type, no border. Multiline
                // stays — only the container's language is shared.
                TextField("Add a note for later", text: $note, axis: .vertical)
                    .font(Style.Typography.body())
                    .foregroundColor(Style.Color.primaryText)
                    .tint(Style.Color.composerSend)
                    .lineLimit(1...4)
                    .focused($isNoteFocused)
                    .padding(.vertical, Self.fieldPaddingVertical)
                    .padding(.horizontal, Self.fieldPaddingHorizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Style.Color.composerBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Self.fieldCornerRadius))
                    .onChange(of: note) { _, newValue in
                        if newValue.count > EntryReminder.noteCharacterLimit {
                            note = String(newValue.prefix(EntryReminder.noteCharacterLimit))
                        }
                    }

                Text("This step is optional")
                    .font(Style.Typography.meta())
                    .foregroundColor(Style.Color.secondary)
                    .padding(.leading, Style.Spacing.base)
            }
            .padding(.horizontal, Style.Layout.entryContentPadding)

            if remindersUnavailable {
                permissionBlock
                    .padding(.top, Style.Spacing.x4)
            }

            actions(
                primaryTitle: "Set reminder",
                primaryAction: commit,
                primaryDisabled: isSaving || remindersUnavailable,
                backAction: goBack,
                // The optional-note line sits closer to its field than the
                // other steps' content does, so this step earns a wider
                // gap before the CTA.
                ctaTopSpacing: 24
            )
        }
        .padding(.top, Style.Spacing.x4)
    }

    // MARK: - Actions (primary CTA, quiet Back, Remove)

    /// Every step after the selector ends the same way: the primary action,
    /// a deliberately lighter Back beneath it, and — while editing — the
    /// low-emphasis Remove. Then the sheet's standard bottom inset.
    private func actions(
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        primaryDisabled: Bool = false,
        backAction: @escaping () -> Void,
        ctaTopSpacing: CGFloat = Style.Spacing.x4
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                primaryAction()
            } label: {
                Text(primaryTitle)
                    .font(Style.Typography.authButton())
                    .foregroundColor(Style.Color.composerSendForeground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Capsule().fill(Style.Color.composerSend))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(primaryDisabled)
            .opacity(primaryDisabled ? 0.4 : 1)
            .padding(.horizontal, Style.Layout.entryContentPadding)
            .padding(.top, ctaTopSpacing)

            // Text, not a second pill: Back never competes with the CTA.
            Button {
                isNoteFocused = false
                backAction()
            } label: {
                Text("Back")
                    .font(.custom("DMSans-Medium", size: 14))
                    .foregroundColor(Style.Color.secondary)
                    .frame(height: 44)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, Style.Spacing.base)

            if isEditingExisting {
                Button {
                    onRemove()
                    onDismiss()
                } label: {
                    Text("Remove reminder")
                        .font(.custom("DMSans-Medium", size: 14))
                        .foregroundColor(Style.Color.destructive)
                        .frame(height: 36)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, sheetBottomInset)
    }

    // MARK: - Permission

    private var permissionBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reminders are off")
                .font(.custom("DMSans-Medium", size: 16))
                .foregroundColor(Style.Color.primaryText)

            Text("Turn on notifications so Kebab can bring this back to you.")
                .font(Style.Typography.meta())
                .foregroundColor(Style.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                openSystemSettings()
            } label: {
                Text("Open Settings")
                    .font(.custom("DMSans-Medium", size: 14))
                    .foregroundColor(Style.Color.primaryText)
                    .padding(.horizontal, Style.Spacing.x4)
                    .frame(height: 36)
                    .background(
                        Capsule()
                            .fill(Style.Color.background)
                            .overlay(Capsule().stroke(Style.Color.separator, lineWidth: 1))
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(Style.Spacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Style.Color.composerBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Style.Color.separator, lineWidth: 1)
                )
        )
        .padding(.horizontal, Style.Layout.entryContentPadding)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Navigation

    /// Step changes are the only new motion: a quiet crossfade between
    /// decisions. Every entered value lives in this view's state, so moving
    /// either direction preserves it.
    private func advance(to next: ReminderFlowStep) {
        withAnimation(.easeOut(duration: 0.2)) {
            step = next
        }
    }

    private func goBack() {
        guard let previous = step.back(mode: mode) else { return }
        pastTimeWarning = false
        advance(to: previous)
    }

    private func commit() {
        guard !isSaving else { return }
        isNoteFocused = false
        let target: Date
        if mode == .random {
            // Never regenerated on save — the instant chosen when Random was
            // picked is the one that persists.
            target = ReminderEditing.randomFireAt(
                regenerated: randomFireAt,
                existing: existing?.mode == .random ? existing?.fireAt : nil,
                generate: { ReminderSchedule.randomFireDate(from: Date()) }
            )
        } else {
            target = fireAt
            guard !ReminderSchedule.isInPast(target) else {
                // The chosen time lapsed while they were writing the note:
                // send them back to the step that can fix it.
                withAnimation(.easeOut(duration: 0.2)) {
                    pastTimeWarning = true
                    step = .timing
                }
                return
            }
        }
        isSaving = true
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let outcome = await onSet(mode, target, trimmed.isEmpty ? nil : trimmed)
            isSaving = false
            switch outcome {
            case .saved:
                onDismiss()
            case .permissionDenied:
                withAnimation(.easeOut(duration: 0.2)) { permissionRefused = true }
            case .notConfigured:
                onDismiss()
            }
        }
    }

    // MARK: - Chrome

    private var hairline: some View {
        Rectangle()
            .fill(Style.Color.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Style.Layout.entryContentPadding)
    }
}
