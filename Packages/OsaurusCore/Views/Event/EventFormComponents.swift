//
//  EventFormComponents.swift
//  osaurus
//
//  Shared form pieces for the event editor: schedule frequency pickers,
//  the agent picker, section chrome, text field and button styles.
//

import AppKit
import SwiftUI

// MARK: - Schedule Frequency Draft

/// Editable picker state for a `ScheduleFrequency`.
struct ScheduleFrequencyDraft: Equatable {
    var frequencyType: ScheduleFrequencyType = .daily
    var selectedIntervalMinutes = 30
    var selectedHour = 9
    var selectedMinute = 0
    var selectedDayOfWeek = 2  // Monday
    var selectedDayOfMonth = 1
    var selectedMonth = 1
    var selectedDay = 1
    var selectedDate = Date()
    var cronExpression = "0 9 * * *"

    init() {}

    init(_ frequency: ScheduleFrequency) {
        frequencyType = frequency.frequencyType
        switch frequency {
        case .once(let date):
            selectedDate = date
        case .everyNMinutes(let minutes):
            selectedIntervalMinutes = minutes
        case .hourly(let minute):
            selectedMinute = minute
        case .daily(let hour, let minute):
            selectedHour = hour
            selectedMinute = minute
        case .weekly(let dayOfWeek, let hour, let minute):
            selectedDayOfWeek = dayOfWeek
            selectedHour = hour
            selectedMinute = minute
        case .monthly(let dayOfMonth, let hour, let minute):
            selectedDayOfMonth = dayOfMonth
            selectedHour = hour
            selectedMinute = minute
        case .yearly(let month, let day, let hour, let minute):
            selectedMonth = month
            selectedDay = day
            selectedHour = hour
            selectedMinute = minute
        case .cron(let expression):
            cronExpression = expression
        }
    }

    var frequency: ScheduleFrequency {
        switch frequencyType {
        case .once: .once(date: selectedDate)
        case .everyNMinutes: .everyNMinutes(minutes: selectedIntervalMinutes)
        case .hourly: .hourly(minute: selectedMinute)
        case .daily: .daily(hour: selectedHour, minute: selectedMinute)
        case .weekly: .weekly(dayOfWeek: selectedDayOfWeek, hour: selectedHour, minute: selectedMinute)
        case .monthly: .monthly(dayOfMonth: selectedDayOfMonth, hour: selectedHour, minute: selectedMinute)
        case .yearly: .yearly(month: selectedMonth, day: selectedDay, hour: selectedHour, minute: selectedMinute)
        case .cron: .cron(expression: cronExpression)
        }
    }
}

// MARK: - Schedule Frequency Editor

struct ScheduleFrequencyEditor: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var draft: ScheduleFrequencyDraft

    var body: some View {
        VStack(spacing: theme.space.s16) {
            FrequencySelector(selection: $draft.frequencyType)
            frequencyOptionsView
                .animation(theme.motion.quick, value: draft.frequencyType)
        }
    }

    @ViewBuilder
    private var frequencyOptionsView: some View {
        switch draft.frequencyType {
        case .once:
            onceOptions
        case .everyNMinutes:
            everyNMinutesOptions
        case .hourly:
            hourlyOptions
        case .daily:
            dailyOptions
        case .weekly:
            weeklyOptions
        case .monthly:
            monthlyOptions
        case .yearly:
            yearlyOptions
        case .cron:
            cronOptions
        }
    }

    private var cronOptions: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("Cron Expression", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)

                SettingsTextField(
                    placeholder: "e.g., 15 0,7 * * 1-5",
                    text: $draft.cronExpression,
                    icon: "terminal"
                )
            }

            Text("Format: minute hour day-of-month month day-of-week", bundle: .module)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                .foregroundColor(theme.text.secondary)

            Text("Supports standard 5 field format with * , - and / operators", bundle: .module)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)

            if let nextRun = CronParser(draft.cronExpression)?.nextDate(after: Date()) {
                schedulePreview(text: "Next run: \(formattedDate(nextRun))")
            } else {
                schedulePreview(text: "Invalid cron expression", isError: true)
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var onceOptions: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            HStack(spacing: theme.space.s16) {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    Text("Date", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)

                    OnceDatePicker(selectedDate: $draft.selectedDate)
                }

                VStack(alignment: .leading, spacing: theme.space.s6) {
                    Text("Time", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)

                    OnceTimePicker(selectedDate: $draft.selectedDate)
                }

                Spacer()
            }

            oncePreview
        }
    }

    private var oncePreview: some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: "calendar.badge.clock")
                .glyphSize(14, weight: .medium)
                .foregroundColor(theme.text.link)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text("Scheduled for", bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                    .foregroundColor(theme.text.tertiary)
                Text(formattedOnceDate)
                    .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
            }

            Spacer()
        }
        .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
        .settingsChrome(.selected)
    }

    private var formattedOnceDate: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(draft.selectedDate) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if calendar.isDateInTomorrow(draft.selectedDate) {
            formatter.dateFormat = "'Tomorrow at' h:mm a"
        } else {
            formatter.dateFormat = "EEEE, MMM d, yyyy 'at' h:mm a"
        }

        return formatter.string(from: draft.selectedDate)
    }

    // MARK: - Every N Minutes Options

    private let minuteIntervalChoices = [5, 10, 15, 20, 30, 45]

    private var everyNMinutesOptions: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                Text("Interval", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)

                HStack(spacing: theme.space.s6) {
                    ForEach(minuteIntervalChoices, id: \.self) { interval in
                        Button {
                            withAnimation(theme.motion.springAnimation) {
                                draft.selectedIntervalMinutes = interval
                            }
                        } label: {
                            Text("\(interval)m", bundle: .module)
                                .componentInspectionText(50, role: .caption, fallback: .caption, weight: draft.selectedIntervalMinutes == interval ? 600 : 500, theme: theme)
                                .foregroundColor(
                                    draft.selectedIntervalMinutes == interval
                                        ? theme.action.primary.default.foreground
                                        : theme.text.secondary
                                )
                                .frame(minWidth: 40, minHeight: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: theme.radius.medium)
                                        .fill(
                                            draft.selectedIntervalMinutes == interval
                                                ? theme.action.primary.default.background
                                                : theme.surface.raised
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: theme.radius.medium)
                                                .stroke(
                                                    draft.selectedIntervalMinutes == interval
                                                        ? theme.action.primary.default.background
                                                        : theme.border.strong,
                                                    lineWidth: theme.stroke.default
                                                )
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            schedulePreview(text: everyNMinutesPreviewText)
        }
    }

    private var everyNMinutesPreviewText: String {
        "Every \(draft.selectedIntervalMinutes) minutes"
    }

    // MARK: - Hourly Options

    private var hourlyOptions: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("Minute of Hour", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)

                HourlyMinutePicker(minute: $draft.selectedMinute)
            }

            schedulePreview(text: hourlyPreviewText)
        }
    }

    private var hourlyPreviewText: String {
        "Every hour at :\(String(format: "%02d", draft.selectedMinute))"
    }

    // MARK: - Daily Options

    private var dailyOptions: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("Time", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)

                timePicker
            }

            schedulePreview(text: dailyPreviewText)
        }
    }

    private var dailyPreviewText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var components = DateComponents()
        components.hour = draft.selectedHour
        components.minute = draft.selectedMinute

        if let date = Calendar.current.date(from: components) {
            return "Every day at \(formatter.string(from: date))"
        }
        return "Every day at \(draft.selectedHour):\(String(format: "%02d", draft.selectedMinute))"
    }

    private var weeklyOptions: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                Text("Day of Week", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)

                HStack(spacing: theme.space.s6) {
                    ForEach(1 ... 7, id: \.self) { day in
                        WeekdayButton(
                            day: day,
                            isSelected: draft.selectedDayOfWeek == day,
                            action: {
                                withAnimation(theme.motion.springAnimation) {
                                    draft.selectedDayOfWeek = day
                                }
                            }
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("Time", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)

                timePicker
            }

            schedulePreview(text: weeklyPreviewText)
        }
    }

    private var weeklyPreviewText: String {
        let dayName = Calendar.current.weekdaySymbols[draft.selectedDayOfWeek - 1]
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var components = DateComponents()
        components.hour = draft.selectedHour
        components.minute = draft.selectedMinute

        if let date = Calendar.current.date(from: components) {
            return "Every \(dayName) at \(formatter.string(from: date))"
        }
        return "Every \(dayName)"
    }

    private var monthlyOptions: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            HStack(spacing: theme.space.s16) {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    Text("Day of Month", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)

                    DayOfMonthPicker(selectedDay: $draft.selectedDayOfMonth)
                }

                VStack(alignment: .leading, spacing: theme.space.s6) {
                    Text("Time", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)

                    timePicker
                }

                Spacer()
            }

            Text("If the day doesn't exist in a month, it will run on the last day.", bundle: .module)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
                .padding(.horizontal, theme.space.s4)

            schedulePreview(text: monthlyPreviewText)
        }
    }

    private var monthlyPreviewText: String {
        let suffix = daySuffix(draft.selectedDayOfMonth)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var components = DateComponents()
        components.hour = draft.selectedHour
        components.minute = draft.selectedMinute

        if let date = Calendar.current.date(from: components) {
            return "Monthly on the \(draft.selectedDayOfMonth)\(suffix) at \(formatter.string(from: date))"
        }
        return "Monthly on the \(draft.selectedDayOfMonth)\(suffix)"
    }

    private func daySuffix(_ day: Int) -> String {
        switch day {
        case 1, 21, 31: return "st"
        case 2, 22: return "nd"
        case 3, 23: return "rd"
        default: return "th"
        }
    }

    private var yearlyOptions: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            HStack(spacing: theme.space.s12) {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    Text("Month", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)

                    MonthPicker(selectedMonth: $draft.selectedMonth)
                }

                VStack(alignment: .leading, spacing: theme.space.s6) {
                    Text("Day", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)

                    DayOfMonthPicker(selectedDay: $draft.selectedDay)
                }

                VStack(alignment: .leading, spacing: theme.space.s6) {
                    Text("Time", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)

                    timePicker
                }

                Spacer()
            }

            schedulePreview(text: yearlyPreviewText)
        }
    }

    private var yearlyPreviewText: String {
        let monthName = Calendar.current.monthSymbols[draft.selectedMonth - 1]
        let suffix = daySuffix(draft.selectedDay)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var components = DateComponents()
        components.hour = draft.selectedHour
        components.minute = draft.selectedMinute

        if let date = Calendar.current.date(from: components) {
            return "Yearly on \(monthName) \(draft.selectedDay)\(suffix) at \(formatter.string(from: date))"
        }
        return "Yearly on \(monthName) \(draft.selectedDay)\(suffix)"
    }

    private var timePicker: some View {
        ScheduleTimePicker(hour: $draft.selectedHour, minute: $draft.selectedMinute)
    }

    // Helper view for schedule preview
    private func schedulePreview(text: String, isError: Bool = false) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "repeat")
                .glyphSize(14, weight: .medium)
                .foregroundColor(isError ? theme.status.error.foreground : theme.text.link)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(isError ? L("Error") : L("Schedule"))
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                    .foregroundColor(isError ? theme.status.error.foreground : theme.text.tertiary)
                Text(text)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(isError ? theme.status.error.foreground : theme.text.primary)
            }

            Spacer()
        }
        .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(isError ? theme.status.error.background : theme.status.info.background)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .stroke(isError ? theme.status.error.border : theme.status.info.border, lineWidth: theme.stroke.default)
                )
        )
    }
}

// MARK: - Frequency Dropdown Selector

struct FrequencySelector: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var selection: ScheduleFrequencyType

    @State private var isHovering = false
    @State private var showingPopover = false

    var body: some View {
        SettingsPopUpButton(style: .field, isActive: showingPopover) {
            showingPopover.toggle()
        } label: {
            HStack(spacing: theme.space.s8) {
                Image(systemName: selection.icon)
                    .glyphSize(12, weight: .medium)
                    .foregroundColor(theme.text.link)

                Text(selection.rawValue)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                ForEach(ScheduleFrequencyType.allCases, id: \.self) { type in
                    FrequencyOptionRow(
                        type: type,
                        isSelected: selection == type,
                        action: {
                            withAnimation(theme.motion.springAnimation) {
                                selection = type
                            }
                            showingPopover = false
                        }
                    )
                }
            }
            .padding(.horizontal, theme.space.s6).padding(.vertical, theme.space.s6)
            .frame(width: 200)
            .background(theme.surface.raised)
        }
    }
}

struct FrequencyOptionRow: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let type: ScheduleFrequencyType
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: type.icon)
                    .glyphSize(11, weight: .medium)
                    .foregroundColor(isSelected ? theme.text.link : theme.text.secondary)
                    .frame(width: 16)

                Text(type.rawValue)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .glyphSize(11, weight: .semibold)
                        .foregroundColor(theme.text.link)
                }
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(
                        isHovering
                            ? theme.surface.hover
                            : (isSelected ? theme.surface.selected : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Schedule Time Picker

struct ScheduleTimePicker: View {
    #if OSAURUS_DESIGN_SYSTEM
    @State private var inspectorComposing = false
    #endif

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    @Binding var hour: Int
    @Binding var minute: Int

    @State private var hourText: String = ""
    @State private var minuteText: String = ""
    @State private var isFocused = false
    @FocusState private var hourFocused: Bool
    @FocusState private var minuteFocused: Bool

    private var period: String {
        hour >= 12 ? "PM" : "AM"
    }

    private var displayHour: Int {
        let h = hour % 12
        return h == 0 ? 12 : h
    }

    var body: some View {
        HStack(spacing: theme.space.s4) {
            Image(systemName: "clock")
                .glyphSize(12, weight: .medium)
                .foregroundColor(theme.assignedColor("component.library.8.elements.label.foreground", fallback: theme.text.link))
                .nativeCatalogTarget(["component.library.8.elements.label.foreground"], "Clock icon")

            Group {
                #if OSAURUS_DESIGN_SYSTEM
                InspectorAssignedTextField(text: $hourText, isComposing: $inspectorComposing,
                    font: theme.assignedNativeFont("component.library.8.text", fallback: theme.nsFont(.label)),
                    textColor: NSColor(theme.assignedColor("component.library.8." + (inspectionEnabled ? "foreground" : "disabledForeground"), fallback: theme.text.primary)), onSubmit: validateHour,
                    onFocusChange: { hourFocused = $0 }, tracking: theme.assignedTracking("component.library.8.text"),
                    editable: inspectionEnabled, requestedFocus: hourFocused, alignment: .center)
                    .frame(minHeight: theme.assignedLineHeight("component.library.8.text", fallback: theme.scaledTextStyle(.label).lineHeight))
                #else
                TextField("", text: $hourText)
                #endif
            }
                .textFieldStyle(.plain)
                .assignedTypography("component.library.8.text", fallback: SettingsFont.rowTitle)
                .nativeCatalogTarget(["component.library.8.elements.body.text", "component.library.8.elements.body.foreground", "component.library.8.elements.body.disabledForeground"], "Hours and minutes")
                .foregroundColor(theme.text.primary)
                .frame(width: inspectionNumberWidth(24))
                .multilineTextAlignment(.center)
                .focused($hourFocused)
                .onAppear {
                    hourText = "\(displayHour)"
                }
                .onChange(of: hour) { _, _ in
                    if !hourFocused {
                        hourText = "\(displayHour)"
                    }
                }
                .onSubmit { validateHour() }
                .onChange(of: hourFocused) { _, focused in
                    isFocused = focused || minuteFocused
                    if !focused { validateHour() }
                }
                .onChange(of: hourText) { _, _ in
                    if hourFocused { commitHourLive() }
                }

            Text(":")
                .assignedTypography("component.library.8.text", fallback: SettingsFont.rowTitle)
                .foregroundColor(theme.assignedColor("component.library.8.secondary", fallback: theme.text.secondary))
                .nativeCatalogTarget(["component.library.8.elements.supportingText.secondary"], "Time separator")

            Group {
                #if OSAURUS_DESIGN_SYSTEM
                InspectorAssignedTextField(text: $minuteText, isComposing: $inspectorComposing,
                    font: theme.assignedNativeFont("component.library.8.text", fallback: theme.nsFont(.label)),
                    textColor: NSColor(theme.assignedColor("component.library.8." + (inspectionEnabled ? "foreground" : "disabledForeground"), fallback: theme.text.primary)), onSubmit: validateMinute,
                    onFocusChange: { minuteFocused = $0 }, tracking: theme.assignedTracking("component.library.8.text"),
                    editable: inspectionEnabled, requestedFocus: minuteFocused, alignment: .center)
                    .frame(minHeight: theme.assignedLineHeight("component.library.8.text", fallback: theme.scaledTextStyle(.label).lineHeight))
                #else
                TextField("", text: $minuteText)
                #endif
            }
                .textFieldStyle(.plain)
                .assignedTypography("component.library.8.text", fallback: SettingsFont.rowTitle)
                .nativeCatalogTarget(["component.library.8.elements.body.text", "component.library.8.elements.body.foreground", "component.library.8.elements.body.disabledForeground"], "Hours and minutes")
                .foregroundColor(theme.text.primary)
                .frame(width: inspectionNumberWidth(24))
                .multilineTextAlignment(.center)
                .focused($minuteFocused)
                .onAppear {
                    minuteText = String(format: "%02d", minute)
                }
                .onChange(of: minute) { _, newValue in
                    if !minuteFocused {
                        minuteText = String(format: "%02d", newValue)
                    }
                }
                .onSubmit { validateMinute() }
                .onChange(of: minuteFocused) { _, focused in
                    isFocused = hourFocused || focused
                    if !focused { validateMinute() }
                }
                .onChange(of: minuteText) { _, _ in
                    if minuteFocused { commitMinuteLive() }
                }

            Button(action: togglePeriod) {
                Text(period)
                    .assignedTimePeriod(theme: theme, enabled: inspectionEnabled)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("AM or PM")
            .accessibilityValue(period)
        }
        .frame(minHeight: inspectionFieldHeight)
        .assignedTimeField(theme: theme, focused: isFocused, enabled: inspectionEnabled)
    }

    private func validateHour() {
        if let value = Int(hourText), value >= 1, value <= 12 {
            let isPM = hour >= 12
            if value == 12 {
                hour = isPM ? 12 : 0
            } else {
                hour = isPM ? value + 12 : value
            }
        }
        hourText = "\(displayHour)"
    }

    /// Same clamp/AM-PM math as `validateHour`, but never rewrites
    /// `hourText` — leaves the user's in-progress edit alone.
    private func commitHourLive() {
        guard let value = Int(hourText), value >= 1, value <= 12 else { return }
        let isPM = hour >= 12
        if value == 12 {
            hour = isPM ? 12 : 0
        } else {
            hour = isPM ? value + 12 : value
        }
    }

    private func validateMinute() {
        if let value = Int(minuteText), value >= 0, value <= 59 {
            minute = value
        }
        minuteText = String(format: "%02d", minute)
    }

    private func commitMinuteLive() {
        guard let value = Int(minuteText), value >= 0, value <= 59 else { return }
        minute = value
    }

    private func togglePeriod() {
        if hour >= 12 {
            hour -= 12
        } else {
            hour += 12
        }
    }

    private func inspectionNumberWidth(_ fallback: CGFloat) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return max(fallback, twoDigitWidth(theme.assignedNativeFont("component.library.8.text", fallback: theme.nsFont(.label))))
        #else
        return fallback
        #endif
    }
    private var inspectionFieldHeight: CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return max(NativeComponentInspectionStyle.metric(8, "height", 38, theme), theme.assignedLineHeight("component.library.8.text", fallback: theme.lineHeight(.label)) + 6)
        #else
        return 38
        #endif
    }
}

// MARK: - Hourly Minute Picker

struct HourlyMinutePicker: View {
    #if OSAURUS_DESIGN_SYSTEM
    @State private var inspectorComposing = false
    #endif

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var minute: Int

    @State private var minuteText: String = ""
    @State private var isFocused = false
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        HStack(spacing: theme.space.s4) {
            Image(systemName: "clock")
                .glyphSize(12, weight: .medium)
                .foregroundColor(theme.text.link)
                .padding(.leading, theme.space.s8)

            Text(":")
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
                .foregroundColor(theme.text.secondary)

            Group {
                #if OSAURUS_DESIGN_SYSTEM
                InspectorAssignedTextField(text: $minuteText, isComposing: $inspectorComposing,
                    font: theme.assignedNativeFont("component.library.50.label", fallback: theme.nsFont(.label)),
                    textColor: NSColor(theme.text.primary), onSubmit: validateMinute,
                    onFocusChange: { textFieldFocused = $0 }, tracking: theme.assignedTracking("component.library.50.label"),
                    editable: inspectionEnabled, requestedFocus: textFieldFocused, alignment: .center)
                    .frame(minHeight: theme.assignedLineHeight("component.library.50.label", fallback: theme.scaledTextStyle(.label).lineHeight))
                #else
                TextField("", text: $minuteText)
                #endif
            }
                .textFieldStyle(.plain)
                .componentInspectionText(50, role: .label, fallback: .label, theme: theme)
                .foregroundColor(theme.text.primary)
                .frame(width: inspectionNumberWidth(28))
                .multilineTextAlignment(.center)
                .focused($textFieldFocused)
                .onAppear {
                    minuteText = String(format: "%02d", minute)
                }
                .onChange(of: minute) { _, newValue in
                    if !textFieldFocused {
                        minuteText = String(format: "%02d", newValue)
                    }
                }
                .onSubmit { validateMinute() }
                .onChange(of: textFieldFocused) { _, focused in
                    isFocused = focused
                    if !focused { validateMinute() }
                }
                // See `ScheduleTimePicker` — commit live so previews and
                // an immediate Save reflect the typed value without
                // requiring focus loss first.
                .onChange(of: minuteText) { _, _ in
                    if textFieldFocused { commitMinuteLive() }
                }

            VStack(spacing: 0) {
                Button(action: { incrementMinute() }) {
                    Image(systemName: "chevron.up")
                        .glyphSize(8, weight: .bold)
                        .foregroundColor(theme.text.secondary)
                        .frame(width: 20, height: 12)
                }
                .buttonStyle(.plain)

                Button(action: { decrementMinute() }) {
                    Image(systemName: "chevron.down")
                        .glyphSize(8, weight: .bold)
                        .foregroundColor(theme.text.secondary)
                        .frame(width: 20, height: 12)
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, theme.space.s8)
        }
        .frame(height: inspectionFieldHeight)
        .settingsChrome(.control)
        .settingsFocusRing(isFocused, radius: theme.radius.medium)
    }

    private func validateMinute() {
        if let value = Int(minuteText), value >= 0, value <= 59 {
            minute = value
        }
        minuteText = String(format: "%02d", minute)
    }

    private func commitMinuteLive() {
        guard let value = Int(minuteText), value >= 0, value <= 59 else { return }
        minute = value
    }

    private func incrementMinute() {
        minute = (minute + 1) % 60
        minuteText = String(format: "%02d", minute)
    }

    private func decrementMinute() {
        minute = (minute + 59) % 60
        minuteText = String(format: "%02d", minute)
    }

    private func inspectionNumberWidth(_ fallback: CGFloat) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return max(fallback, twoDigitWidth(theme.nsFont(.label)))
        #else
        return fallback
        #endif
    }
    private var inspectionFieldHeight: CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return max(NativeComponentInspectionStyle.metric(50, "height", 38, theme), theme.lineHeight(.label) + 4)
        #else
        return 38
        #endif
    }
}

// MARK: - Weekday Button

struct WeekdayButton: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let day: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var dayLetter: String {
        String(Calendar.current.veryShortWeekdaySymbols[day - 1])
    }

    var body: some View {
        Button(action: action) {
            Text(dayLetter)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                .foregroundColor(
                    isSelected
                        ? theme.inspectionColor("component.library.50.onForeground", fallback: .white)
                        : (isHovering ? theme.text.primary : theme.text.secondary)
                )
                .frame(width: theme.catalogMetric("height", fallback: 34), height: theme.catalogMetric("height", fallback: 34))
                .background(
                    Circle()
                        .fill(
                            isSelected
                                ? theme.action.primary.default.background
                                : (isHovering
                                    ? theme.surface.hover
                                    : theme.surface.raised)
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    isSelected
                                        ? theme.action.primary.default.background
                                        : (isHovering
                                            ? theme.text.secondary
                                            : theme.border.strong),
                                    lineWidth: theme.stroke.default
                                )
                        )
                )
                .scaleEffect(isHovering && !isSelected ? 1.05 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Once Date Picker

struct OnceDatePicker: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var selectedDate: Date

    @State private var isHovering = false
    @State private var showingPopover = false

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: selectedDate)
    }

    var body: some View {
        SettingsPopUpButton(style: .field, isActive: showingPopover, fillsWidth: false) {
            showingPopover.toggle()
        } label: {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "calendar")
                    .glyphSize(12, weight: .medium)
                    .foregroundColor(theme.text.link)

                Text(formattedDate)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                DatePicker(
                    "",
                    selection: $selectedDate,
                    in: Date()...,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
            }
            .background(theme.surface.raised)
        }
    }
}

// MARK: - Once Time Picker

struct OnceTimePicker: View {
    #if OSAURUS_DESIGN_SYSTEM
    @State private var inspectorComposing = false
    #endif

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var selectedDate: Date

    @State private var hourText: String = ""
    @State private var minuteText: String = ""
    @State private var isFocused = false
    @FocusState private var hourFocused: Bool
    @FocusState private var minuteFocused: Bool

    private var hour: Int {
        Calendar.current.component(.hour, from: selectedDate)
    }

    private var minute: Int {
        Calendar.current.component(.minute, from: selectedDate)
    }

    private var period: String {
        hour >= 12 ? "PM" : "AM"
    }

    private var displayHour: Int {
        let h = hour % 12
        return h == 0 ? 12 : h
    }

    private func updateHour(_ newHour: Int) {
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: selectedDate)
        components.hour = newHour
        if let newDate = Calendar.current.date(from: components) {
            selectedDate = newDate
        }
    }

    private func updateMinute(_ newMinute: Int) {
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: selectedDate)
        components.minute = newMinute
        if let newDate = Calendar.current.date(from: components) {
            selectedDate = newDate
        }
    }

    var body: some View {
        HStack(spacing: theme.space.s4) {
            Image(systemName: "clock")
                .glyphSize(12, weight: .medium)
                .foregroundColor(theme.assignedColor("component.library.8.elements.label.foreground", fallback: theme.text.link))
                .nativeCatalogTarget(["component.library.8.elements.label.foreground"], "Clock icon")

            Group {
                #if OSAURUS_DESIGN_SYSTEM
                InspectorAssignedTextField(text: $hourText, isComposing: $inspectorComposing,
                    font: theme.assignedNativeFont("component.library.8.text", fallback: theme.nsFont(.label)),
                    textColor: NSColor(theme.assignedColor("component.library.8." + (inspectionEnabled ? "foreground" : "disabledForeground"), fallback: theme.text.primary)), onSubmit: validateHour,
                    onFocusChange: { hourFocused = $0 }, tracking: theme.assignedTracking("component.library.8.text"),
                    editable: inspectionEnabled, requestedFocus: hourFocused, alignment: .center)
                    .frame(minHeight: theme.assignedLineHeight("component.library.8.text", fallback: theme.scaledTextStyle(.label).lineHeight))
                #else
                TextField("", text: $hourText)
                #endif
            }
                .textFieldStyle(.plain)
                .assignedTypography("component.library.8.text", fallback: SettingsFont.rowTitle)
                .nativeCatalogTarget(["component.library.8.elements.body.text", "component.library.8.elements.body.foreground", "component.library.8.elements.body.disabledForeground"], "Hours and minutes")
                .foregroundColor(theme.text.primary)
                .frame(width: inspectionNumberWidth(24))
                .multilineTextAlignment(.center)
                .focused($hourFocused)
                .onAppear {
                    hourText = "\(displayHour)"
                }
                .onChange(of: hour) { _, _ in
                    if !hourFocused {
                        hourText = "\(displayHour)"
                    }
                }
                .onSubmit { validateHour() }
                .onChange(of: hourFocused) { _, focused in
                    isFocused = focused || minuteFocused
                    if !focused { validateHour() }
                }
                .onChange(of: hourText) { _, _ in
                    if hourFocused { commitHourLive() }
                }

            Text(":")
                .assignedTypography("component.library.8.text", fallback: SettingsFont.rowTitle)
                .foregroundColor(theme.assignedColor("component.library.8.secondary", fallback: theme.text.secondary))
                .nativeCatalogTarget(["component.library.8.elements.supportingText.secondary"], "Time separator")

            Group {
                #if OSAURUS_DESIGN_SYSTEM
                InspectorAssignedTextField(text: $minuteText, isComposing: $inspectorComposing,
                    font: theme.assignedNativeFont("component.library.8.text", fallback: theme.nsFont(.label)),
                    textColor: NSColor(theme.assignedColor("component.library.8." + (inspectionEnabled ? "foreground" : "disabledForeground"), fallback: theme.text.primary)), onSubmit: validateMinute,
                    onFocusChange: { minuteFocused = $0 }, tracking: theme.assignedTracking("component.library.8.text"),
                    editable: inspectionEnabled, requestedFocus: minuteFocused, alignment: .center)
                    .frame(minHeight: theme.assignedLineHeight("component.library.8.text", fallback: theme.scaledTextStyle(.label).lineHeight))
                #else
                TextField("", text: $minuteText)
                #endif
            }
                .textFieldStyle(.plain)
                .assignedTypography("component.library.8.text", fallback: SettingsFont.rowTitle)
                .nativeCatalogTarget(["component.library.8.elements.body.text", "component.library.8.elements.body.foreground", "component.library.8.elements.body.disabledForeground"], "Hours and minutes")
                .foregroundColor(theme.text.primary)
                .frame(width: inspectionNumberWidth(24))
                .multilineTextAlignment(.center)
                .focused($minuteFocused)
                .onAppear {
                    minuteText = String(format: "%02d", minute)
                }
                .onChange(of: minute) { _, newValue in
                    if !minuteFocused {
                        minuteText = String(format: "%02d", newValue)
                    }
                }
                .onSubmit { validateMinute() }
                .onChange(of: minuteFocused) { _, focused in
                    isFocused = hourFocused || focused
                    if !focused { validateMinute() }
                }
                .onChange(of: minuteText) { _, _ in
                    if minuteFocused { commitMinuteLive() }
                }

            Button(action: togglePeriod) {
                Text(period)
                    .assignedTimePeriod(theme: theme, enabled: inspectionEnabled)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("AM or PM")
            .accessibilityValue(period)
        }
        .frame(minHeight: inspectionFieldHeight)
        .assignedTimeField(theme: theme, focused: isFocused, enabled: inspectionEnabled)
    }

    private func validateHour() {
        if let value = Int(hourText), value >= 1, value <= 12 {
            let isPM = hour >= 12
            if value == 12 {
                updateHour(isPM ? 12 : 0)
            } else {
                updateHour(isPM ? value + 12 : value)
            }
        }
        hourText = "\(displayHour)"
    }

    private func commitHourLive() {
        guard let value = Int(hourText), value >= 1, value <= 12 else { return }
        let isPM = hour >= 12
        if value == 12 {
            updateHour(isPM ? 12 : 0)
        } else {
            updateHour(isPM ? value + 12 : value)
        }
    }

    private func validateMinute() {
        if let value = Int(minuteText), value >= 0, value <= 59 {
            updateMinute(value)
        }
        minuteText = String(format: "%02d", minute)
    }

    private func commitMinuteLive() {
        guard let value = Int(minuteText), value >= 0, value <= 59 else { return }
        updateMinute(value)
    }

    private func togglePeriod() {
        if hour >= 12 {
            updateHour(hour - 12)
        } else {
            updateHour(hour + 12)
        }
    }

    private func inspectionNumberWidth(_ fallback: CGFloat) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return max(fallback, twoDigitWidth(theme.assignedNativeFont("component.library.8.text", fallback: theme.nsFont(.label))))
        #else
        return fallback
        #endif
    }
    private var inspectionFieldHeight: CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return max(NativeComponentInspectionStyle.metric(8, "height", 38, theme), theme.assignedLineHeight("component.library.8.text", fallback: theme.lineHeight(.label)) + 6)
        #else
        return 38
        #endif
    }
}

// MARK: - Month Picker

struct MonthPicker: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var selectedMonth: Int

    @State private var isHovering = false
    @State private var showingPopover = false

    private var monthName: String {
        Calendar.current.monthSymbols[selectedMonth - 1]
    }

    var body: some View {
        SettingsPopUpButton(style: .field, isActive: showingPopover, fillsWidth: false) {
            showingPopover.toggle()
        } label: {
            HStack(spacing: theme.space.s4) {
                Text(monthName)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                ForEach(1 ... 12, id: \.self) { month in
                    MonthOptionRow(
                        month: month,
                        isSelected: selectedMonth == month,
                        action: {
                            selectedMonth = month
                            showingPopover = false
                        }
                    )
                }
            }
            .padding(.horizontal, theme.space.s6).padding(.vertical, theme.space.s6)
            .frame(width: 160)
            .background(theme.surface.raised)
        }
    }
}

// MARK: - Month Option Row

struct MonthOptionRow: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let month: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var monthName: String {
        Calendar.current.monthSymbols[month - 1]
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(monthName)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .glyphSize(11, weight: .semibold)
                        .foregroundColor(theme.text.link)
                }
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.small)
                    .fill(
                        isHovering
                            ? theme.surface.hover
                            : (isSelected ? theme.surface.selected : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Day of Month Input

struct DayOfMonthPicker: View {
    #if OSAURUS_DESIGN_SYSTEM
    @State private var inspectorComposing = false
    #endif

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @Binding var selectedDay: Int

    @State private var dayText: String = ""
    @State private var isFocused = false
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Group {
                #if OSAURUS_DESIGN_SYSTEM
                InspectorAssignedTextField(text: $dayText, isComposing: $inspectorComposing,
                    font: theme.assignedNativeFont("component.library.50.label", fallback: theme.nsFont(.label)),
                    textColor: NSColor(theme.text.primary), onSubmit: validateAndUpdateDay,
                    onFocusChange: { textFieldFocused = $0 }, tracking: theme.assignedTracking("component.library.50.label"),
                    editable: inspectionEnabled, requestedFocus: textFieldFocused, alignment: .center)
                    .frame(minHeight: theme.assignedLineHeight("component.library.50.label", fallback: theme.scaledTextStyle(.label).lineHeight))
                #else
                TextField("", text: $dayText)
                #endif
            }
                .textFieldStyle(.plain)
                .componentInspectionText(50, role: .label, fallback: .label, theme: theme)
                .foregroundColor(theme.text.primary)
                .frame(width: inspectionNumberWidth(32))
                .multilineTextAlignment(.center)
                .focused($textFieldFocused)
                .onAppear {
                    dayText = "\(selectedDay)"
                }
                .onChange(of: selectedDay) { _, newValue in
                    if !textFieldFocused {
                        dayText = "\(newValue)"
                    }
                }
                .onChange(of: dayText) { _, newValue in
                    if let value = Int(newValue), value >= 1, value <= 31 {
                        selectedDay = value
                    }
                }
                .onSubmit {
                    validateAndUpdateDay()
                }
                .onChange(of: textFieldFocused) { _, focused in
                    isFocused = focused
                    if !focused {
                        validateAndUpdateDay()
                    }
                }

            VStack(spacing: 0) {
                Button(action: { incrementDay() }) {
                    Image(systemName: "chevron.up")
                        .glyphSize(8, weight: .bold)
                        .foregroundColor(theme.text.secondary)
                        .frame(width: 20, height: 12)
                }
                .buttonStyle(.plain)

                Button(action: { decrementDay() }) {
                    Image(systemName: "chevron.down")
                        .glyphSize(8, weight: .bold)
                        .foregroundColor(theme.text.secondary)
                        .frame(width: 20, height: 12)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, theme.space.s8)
        .frame(height: inspectionFieldHeight)
        .settingsChrome(.control)
        .settingsFocusRing(isFocused, radius: theme.radius.medium)
    }

    private func validateAndUpdateDay() {
        if let value = Int(dayText) {
            selectedDay = min(max(value, 1), 31)
        }
        dayText = "\(selectedDay)"
    }

    private func incrementDay() {
        selectedDay = selectedDay < 31 ? selectedDay + 1 : 1
        dayText = "\(selectedDay)"
    }

    private func decrementDay() {
        selectedDay = selectedDay > 1 ? selectedDay - 1 : 31
        dayText = "\(selectedDay)"
    }

    private func inspectionNumberWidth(_ fallback: CGFloat) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return max(fallback, twoDigitWidth(theme.nsFont(.label)))
        #else
        return fallback
        #endif
    }
    private var inspectionFieldHeight: CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        return max(NativeComponentInspectionStyle.metric(50, "height", 38, theme), theme.lineHeight(.label) + 4)
        #else
        return 38
        #endif
    }
}

// MARK: - Agent Picker

struct AgentPicker: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var inspectorEnabled
    private var theme: any ThemeProtocol { baseTheme }
    /// Local agent (`.local`) or a teammate's shared agent (`.workspace`).
    @Binding var selectedTarget: AgentDispatchTarget?
    let agents: [Agent]
    /// Shared agents from every joined workspace, minus this instance's own.
    let workspaceAgents: [WorkspaceAgentPickerOption]

    @State private var isHovering = false
    @State private var showingPopover = false

    private var selectedAgentId: UUID? { selectedTarget?.localId }

    private var selectedAgent: Agent? {
        if let id = selectedAgentId {
            return agents.first(where: { $0.id == id })
        }
        return nil
    }

    private var selectedWorkspaceOption: WorkspaceAgentPickerOption? {
        guard let ref = selectedTarget?.workspaceRef else { return nil }
        return WorkspaceAgentPickerOption.resolve(ref, in: workspaceAgents)
    }

    private var selectedAgentName: String {
        if let option = selectedWorkspaceOption { return option.name }
        return selectedAgent?.name ?? L("Default")
    }

    private var selectedAgentDescription: String? {
        if let option = selectedWorkspaceOption {
            let purpose = AgentDescriptionPolicy.normalized(option.description ?? "")
            return purpose.isEmpty ? option.subtitle : "\(option.subtitle) — \(purpose)"
        }
        if selectedAgentId == nil {
            return L("Uses the default system behavior")
        }
        let desc = selectedAgent?.routingDescription ?? ""
        return desc.isEmpty ? nil : desc
    }

    private var hasDescription: Bool {
        selectedAgentDescription != nil
    }

    private func agentColor(for name: String) -> Color {
        let hue = Double(abs(name.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        SettingsPopUpButton(style: .field, isActive: showingPopover) {
            showingPopover.toggle()
        } label: {
            HStack(spacing: AgentPickerInspectionStyle.metric("gap", 12, theme)) {
                Circle()
                    .fill(agentColor(for: selectedAgentName).opacity(0.2))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: selectedWorkspaceOption == nil ? "person.fill" : "person.2.fill")
                            .glyphSize(14, weight: .medium)
                            .foregroundColor(agentColor(for: selectedAgentName))
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if let option = selectedWorkspaceOption {
                            Circle()
                                .fill(option.presence.agentPickerIndicatorColor(theme: theme, enabled: inspectorEnabled))
                                .frame(width: 9, height: 9)
                                .overlay(Circle().stroke(theme.surface.raised, lineWidth: theme.stroke.default))
                                .help(option.presenceLabel)
                        }
                    }

                if hasDescription {
                    VStack(alignment: .leading, spacing: AgentPickerInspectionStyle.metric("gap", 2, theme)) {
                        Text(selectedAgentName)
                            .agentPickerFont(SettingsFont.rowTitle, property: "label")
                            .agentPickerInk("foreground", fallback: theme.text.primary)

                        Text(selectedAgentDescription!)
                            .agentPickerFont(SettingsFont.rowDescription, property: "text")
                            .agentPickerInk("secondary", fallback: theme.text.tertiary)
                            .lineLimit(1)
                    }
                } else {
                    Text(selectedAgentName)
                        .agentPickerFont(SettingsFont.rowTitle, property: "label")
                        .agentPickerInk("foreground", fallback: theme.text.primary)
                }
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) { pickerContent }
    }

    #if OSAURUS_DESIGN_SYSTEM
    var inspectorMenu: some View { pickerContent }
    #endif

    private var pickerContent: some View {
            VStack(alignment: .leading, spacing: 0) {
                AgentOptionRow(
                    name: "Default",
                    description: "Uses the default system behavior",
                    isSelected: selectedTarget == nil,
                    action: {
                        selectedTarget = nil
                        showingPopover = false
                    }
                )

                if !agents.isEmpty {
                    Divider()
                        .padding(.vertical, AgentPickerInspectionStyle.metric("gap", 4, theme))

                    VStack(alignment: .leading, spacing: theme.space.s4) {
                        ForEach(agents, id: \.id) { agent in
                            AgentOptionRow(
                                name: agent.name,
                                description: agent.routingDescription,
                                isSelected: selectedAgentId == agent.id,
                                action: {
                                    selectedTarget = .local(agent.id)
                                    showingPopover = false
                                }
                            )
                        }
                    }
                }

                if !workspaceAgents.isEmpty {
                    Divider()
                        .padding(.vertical, AgentPickerInspectionStyle.metric("gap", 4, theme))

                    Text("Workspace agents", bundle: .module)
                        .agentPickerFont(SettingsFont.chip, property: "heading")
                        .agentPickerInk("secondary", fallback: theme.text.tertiary)
                        .padding(.horizontal, AgentPickerInspectionStyle.metric("padding", 10, theme))
                        .padding(.bottom, AgentPickerInspectionStyle.metric("gap", 2, theme))

                    VStack(alignment: .leading, spacing: theme.space.s4) {
                        ForEach(workspaceAgents) { option in
                            AgentOptionRow(
                                name: option.name,
                                description: option.description.map { "\(option.subtitle) — \($0)" } ?? option.subtitle,
                                isSelected: selectedTarget?.workspaceRef == option.ref,
                                presence: option.presence,
                                action: {
                                    selectedTarget = .workspace(option.ref)
                                    showingPopover = false
                                }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, AgentPickerInspectionStyle.metric("padding", 8, theme)).padding(.vertical, AgentPickerInspectionStyle.metric("padding", 8, theme))
            .frame(width: 360)
            #if OSAURUS_DESIGN_SYSTEM
            .agentPickerSurface()
            #else
            .background(theme.surface.raised)
            #endif
    }
}

// MARK: - Agent Option Row

struct AgentOptionRow: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var inspectorEnabled
    private var theme: any ThemeProtocol { baseTheme }

    let name: String
    let description: String
    let isSelected: Bool
    /// Cached roster presence for shared workspace agents; nil for local.
    var presence: WorkspaceRosterStore.Presence? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AgentPickerInspectionStyle.metric("gap", 10, theme)) {
                if let presence {
                    Circle()
                        .fill(presence.agentPickerIndicatorColor(theme: theme, enabled: inspectorEnabled))
                        .frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: AgentPickerInspectionStyle.metric("gap", 2, theme)) {
                    Text(name)
                        .agentPickerFont(SettingsFont.rowTitle, property: "label")
                        .agentPickerInk("foreground", fallback: theme.text.primary)

                    if !description.isEmpty {
                        Text(description)
                            .agentPickerFont(SettingsFont.rowDescription, property: "text")
                            .agentPickerInk("secondary", fallback: theme.text.tertiary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .glyphSize(12, weight: .semibold)
                        .agentPickerInk("accent", fallback: theme.text.link)
                }
            }
            .agentPickerRowLayout(horizontal: 10, vertical: 8, selected: isSelected)
            #if !OSAURUS_DESIGN_SYSTEM
            .settingsChrome(isHovering ? .hover : nil)
            #endif
            .contentShape(Rectangle())
        }
        .agentPickerButtonStyle()
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovering = hovering
            }
        }
    }
}


// MARK: - Editor Section

/// One section of the automation editor: the settings section header (with
/// the kind's icon) above one group. Direct children become rows.
struct EventEditorSection<Content: View>: View {
    /// Already localized.
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        SettingsSection(title: title, verbatimTitle: true, icon: icon) {
            content()
        }
    }
}



private struct AssignedTimePeriod: ViewModifier {
    let theme: any ThemeProtocol
    let enabled: Bool
    func body(content: Content) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        let key = "component.library.8.elements.chip."
        content.assignedTypography(key + "text", fallback: SettingsFont.smallLabel)
            .foregroundStyle(theme.assignedColor(key + (enabled ? "foreground" : "disabledForeground"), fallback: theme.text.link))
            .padding(.horizontal, theme.assignedMetric(key + "padding", fallback: 6))
            .padding(.vertical, theme.space.s4)
            .background(RoundedRectangle(cornerRadius: theme.assignedMetric(key + "radius", fallback: theme.radius.medium))
                .fill(theme.assignedColor(key + "selected", fallback: theme.surface.selected)))
            .overlay(RoundedRectangle(cornerRadius: theme.assignedMetric(key + "radius", fallback: theme.radius.medium))
                .strokeBorder(theme.assignedColor(key + "border", fallback: theme.border.default), lineWidth: theme.assignedMetric(key + "borderWidth", fallback: theme.stroke.default)))
            .nativeCatalogTarget(["text", "foreground", "disabledForeground", "padding", "selected", "border", "borderWidth", "radius"].map { key + $0 }, "AM/PM button")
        #else
        content.catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
            .foregroundColor(theme.text.link).padding(.horizontal, theme.space.s6).padding(.vertical, theme.space.s4).settingsChrome(.selected)
        #endif
    }
}
private struct AssignedTimeField: ViewModifier {
    let theme: any ThemeProtocol
    let focused: Bool
    let enabled: Bool
    func body(content: Content) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        let key = "component.library.8.elements.container."
        content.padding(.horizontal, theme.assignedMetric(key + "padding", fallback: 10))
            .assignedBaseChrome(8)
            .assignedBaseFocusRing(8, visible: focused && enabled, radius: theme.assignedMetric(key + "radius", fallback: theme.radius.medium), keyboardOnly: false)
            .nativeCatalogTarget(["padding", "height", "gap", "hover", "disabledBackground"].map { key + $0 } + ["component.library.8.accent"], "Time field")
        #else
        content.padding(.leading, theme.space.s8).padding(.trailing, theme.space.s8).settingsChrome(.control)
            .settingsFocusRing(focused, radius: theme.radius.medium)
        #endif
    }
}
private extension View {
    func assignedTimePeriod(theme: any ThemeProtocol, enabled: Bool) -> some View { modifier(AssignedTimePeriod(theme: theme, enabled: enabled)) }
    func assignedTimeField(theme: any ThemeProtocol, focused: Bool, enabled: Bool) -> some View { modifier(AssignedTimeField(theme: theme, focused: focused, enabled: enabled)) }
}

/// Width of a two-digit numeric field set in `font`, with room for its inset.
private func twoDigitWidth(_ font: NSFont) -> CGFloat {
    ceil(("00" as NSString).size(withAttributes: [.font: font]).width) + 12
}
