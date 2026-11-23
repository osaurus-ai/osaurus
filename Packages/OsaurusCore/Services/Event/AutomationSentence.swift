//
//  AutomationSentence.swift
//  osaurus
//
//  What a workflow automation does, in plain words, for the Workflows
//  screens: a short form for the sidebar ("Weekdays at 8:00 AM") and a long
//  form that follows the workflow's name ("runs every weekday at 8:00 AM").
//  Never says event, trigger, webhook or cron.
//

import Foundation

enum AutomationSentence {
    /// Locale, calendar and time zone the words are formatted in; tests pin
    /// them, the app uses the person's.
    struct Style: Sendable {
        var locale: Locale
        var timeZone: TimeZone

        static var current: Style { Style(locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent) }

        var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            calendar.timeZone = timeZone
            return calendar
        }

        /// "8:00 AM" or "08:00", from the locale's clock.
        func time(hour: Int, minute: Int) -> String {
            var parts = DateComponents()
            parts.hour = hour
            parts.minute = minute
            parts.year = 2001
            parts.month = 1
            parts.day = 1
            guard let date = calendar.date(from: parts) else { return String(format: "%d:%02d", hour, minute) }
            return time(date)
        }

        func time(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }

        /// `template` is a `DateFormatter` skeleton ("MMMd", "MMMMd").
        func date(_ date: Date, template: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: date)
        }

        func monthDay(month: Int, day: Int, template: String) -> String {
            var parts = DateComponents()
            parts.year = 2001
            parts.month = month
            parts.day = day
            parts.hour = 12
            guard let date = calendar.date(from: parts) else { return "\(month)/\(day)" }
            return self.date(date, template: template)
        }

        /// "1st", "22nd".
        func ordinal(_ value: Int) -> String {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .ordinal
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }

        /// "Friday", for `ScheduleFrequency.weekly`'s 1 = Sunday.
        func weekdayName(_ dayOfWeek: Int) -> String {
            let symbols = calendar.standaloneWeekdaySymbols
            let index = (max(1, min(7, dayOfWeek)) - 1)
            return symbols.indices.contains(index) ? symbols[index] : ""
        }
    }

    // MARK: Short

    /// A few words for the sidebar's second line.
    static func short(_ event: OsaurusEvent, style: Style = .current) -> String {
        switch event.source {
        case .schedule(let schedule): return shortSchedule(schedule.frequency, style: style)
        case .folder(let folder): return L("When \(folderName(folder)) changes")
        case .rss(let rss): return L("When \(siteName(rss)) posts")
        case .runFailed: return L("When a run fails")
        case .app(let app):
            return app.fires(on: .appLaunched) ? L("When Osaurus opens") : L("Custom trigger")
        case .macApp(let mac): return L("When \(mac.phrase)")
        case .webhook(let webhook):
            guard let provider = providerName(webhook.provider) else { return L("Custom trigger") }
            return L("When \(provider) has news")
        case .sse: return L("Custom trigger")
        case .email: return L("When new mail arrives")
        case .channelMessage: return L("When a message arrives")
        }
    }

    static func shortSchedule(_ frequency: ScheduleFrequency, style: Style = .current) -> String {
        if let shape = ScheduleCronShape.recognize(frequency) {
            switch shape {
            case .weekdays(let hour, let minute):
                return L("Weekdays at \(style.time(hour: hour, minute: minute))")
            }
        }
        switch frequency {
        case .daily(let hour, let minute):
            return L("Daily at \(style.time(hour: hour, minute: minute))")
        case .weekly(let day, let hour, let minute):
            return L("\(pluralWeekday(day)) at \(style.time(hour: hour, minute: minute))")
        case .hourly:
            return L("Every hour")
        case .everyNMinutes(let minutes):
            return L("Every \(minutes) min")
        case .monthly(let day, _, _):
            return L("Monthly on the \(style.ordinal(day))")
        case .yearly(let month, let day, _, _):
            return L("Yearly on \(style.monthDay(month: month, day: day, template: "MMMd"))")
        case .once(let date):
            return L("Once, \(style.date(date, template: "MMMd"))")
        case .cron:
            return L("Custom schedule")
        }
    }

    // MARK: Long

    /// What follows the workflow's name: "runs every weekday at 8:00 AM".
    static func long(_ event: OsaurusEvent, style: Style = .current) -> String {
        switch event.source {
        case .schedule(let schedule): return longSchedule(schedule.frequency, style: style)
        case .folder(let folder): return L("runs when a file is added to \(folderName(folder))")
        case .rss(let rss): return L("runs when \(siteName(rss)) posts something new")
        case .runFailed: return L("runs when another workflow fails")
        case .app(let app):
            return app.fires(on: .appLaunched) ? L("runs when Osaurus opens") : L("runs from a custom trigger")
        case .macApp(let mac): return L("runs when \(mac.phrase)")
        case .webhook(let webhook):
            guard let provider = providerName(webhook.provider) else { return L("runs from a custom trigger") }
            return L("runs when \(provider) has news")
        case .sse: return L("runs from a custom trigger")
        case .email: return L("runs when new mail arrives")
        case .channelMessage: return L("runs when a message arrives")
        }
    }

    static func longSchedule(_ frequency: ScheduleFrequency, style: Style = .current) -> String {
        if let shape = ScheduleCronShape.recognize(frequency) {
            switch shape {
            case .weekdays(let hour, let minute):
                return L("runs every weekday at \(style.time(hour: hour, minute: minute))")
            }
        }
        switch frequency {
        case .daily(let hour, let minute):
            return L("runs every day at \(style.time(hour: hour, minute: minute))")
        case .weekly(let day, let hour, let minute):
            return L("runs every \(style.weekdayName(day)) at \(style.time(hour: hour, minute: minute))")
        case .hourly:
            return L("runs every hour")
        case .everyNMinutes(let minutes):
            return L("runs every \(minutes) minutes")
        case .monthly(let day, let hour, let minute):
            return L("runs on the \(style.ordinal(day)) of every month at \(style.time(hour: hour, minute: minute))")
        case .yearly(let month, let day, let hour, let minute):
            let date = style.monthDay(month: month, day: day, template: "MMMMd")
            return L("runs every year on \(date) at \(style.time(hour: hour, minute: minute))")
        case .once(let date):
            return L("runs once on \(style.date(date, template: "MMMMd")) at \(style.time(date))")
        case .cron:
            return L("runs on a custom schedule")
        }
    }

    /// The long form as a sentence of its own: "Runs every weekday at 8:00 AM."
    static func sentence(_ event: OsaurusEvent, style: Style = .current) -> String {
        capitalizedFirst(long(event, style: style), locale: style.locale) + "."
    }

    static func capitalizedFirst(_ text: String, locale: Locale) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased(with: locale) + text.dropFirst()
    }

    // MARK: Next run

    /// "today at 8:00 AM", "tomorrow at 8:00 AM", "Friday at 8:00 AM",
    /// "Nov 20 at 8:00 AM": what follows "Next run" in a sentence.
    static func nextRun(_ date: Date, now: Date = Date(), style: Style = .current) -> String {
        let calendar = style.calendar
        let time = style.time(date)
        if calendar.isDate(date, inSameDayAs: now) { return L("today at \(time)") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return L("tomorrow at \(time)")
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days > 0, days < 7 {
            return L("\(style.date(date, template: "EEEE")) at \(time)")
        }
        return L("\(style.date(date, template: "MMMd")) at \(time)")
    }

    // MARK: Editable parts

    /// The day word of a schedule sentence, as the day menu offers it.
    enum DayChoice: Hashable, Sendable {
        case everyDay
        case weekdays
        /// `ScheduleFrequency.weekly`'s day: 1 = Sunday … 7 = Saturday.
        case weekday(Int)
        case everyHour
        case every30Minutes
        case firstOfMonth
        /// Anything the menu can't say; the full editor changes it.
        case custom

        /// Whether a time word follows it.
        var hasTime: Bool {
            switch self {
            case .everyDay, .weekdays, .weekday, .firstOfMonth: return true
            case .everyHour, .every30Minutes, .custom: return false
            }
        }
    }

    /// The day menu, in order. `Custom…` follows it in the view.
    static func dayMenu(style: Style = .current) -> [DayChoice] {
        let first = style.calendar.firstWeekday
        let week = (0..<7).map { (first - 1 + $0) % 7 + 1 }
        return [.everyDay, .weekdays] + week.map(DayChoice.weekday) + [.everyHour, .every30Minutes, .firstOfMonth]
    }

    struct ScheduleParts: Equatable, Sendable {
        var day: DayChoice
        var hour: Int
        var minute: Int
    }

    /// What a card can edit word by word.
    enum Parts: Equatable, Sendable {
        case schedule(ScheduleParts)
        /// The folder's name; the word opens the folder picker.
        case folder(String)
        /// The site; the word opens a field for the feed's address.
        case feed(String)
        /// A sentence the card can't edit in place ("Runs when Osaurus opens.").
        case fixed(String)
    }

    static func parts(_ event: OsaurusEvent, style: Style = .current) -> Parts {
        switch event.source {
        case .schedule(let schedule): return .schedule(scheduleParts(schedule.frequency))
        case .folder(let folder): return .folder(folderName(folder))
        case .rss(let rss): return .feed(siteName(rss))
        default: return .fixed(sentence(event, style: style))
        }
    }

    /// A time the menu falls back to when the schedule has none.
    static let defaultTime = (hour: 9, minute: 0)

    static func scheduleParts(_ frequency: ScheduleFrequency) -> ScheduleParts {
        let fallback = defaultTime
        if case .weekdays(let hour, let minute)? = ScheduleCronShape.recognize(frequency) {
            return ScheduleParts(day: .weekdays, hour: hour, minute: minute)
        }
        switch frequency {
        case .daily(let hour, let minute):
            return ScheduleParts(day: .everyDay, hour: hour, minute: minute)
        case .weekly(let day, let hour, let minute):
            return ScheduleParts(day: .weekday(max(1, min(7, day))), hour: hour, minute: minute)
        case .hourly:
            return ScheduleParts(day: .everyHour, hour: fallback.hour, minute: fallback.minute)
        case .everyNMinutes(30):
            return ScheduleParts(day: .every30Minutes, hour: fallback.hour, minute: fallback.minute)
        case .monthly(1, let hour, let minute):
            return ScheduleParts(day: .firstOfMonth, hour: hour, minute: minute)
        case .monthly(_, let hour, let minute), .yearly(_, _, let hour, let minute):
            return ScheduleParts(day: .custom, hour: hour, minute: minute)
        case .everyNMinutes, .once, .cron:
            return ScheduleParts(day: .custom, hour: fallback.hour, minute: fallback.minute)
        }
    }

    /// The schedule the words say; nil for `.custom`, which only the full
    /// editor writes.
    static func frequency(_ parts: ScheduleParts) -> ScheduleFrequency? {
        let hour = max(0, min(23, parts.hour))
        let minute = max(0, min(59, parts.minute))
        switch parts.day {
        case .everyDay: return .daily(hour: hour, minute: minute)
        case .weekdays: return ScheduleCronShape.weekdays(hour: hour, minute: minute).frequency
        case .weekday(let day): return .weekly(dayOfWeek: max(1, min(7, day)), hour: hour, minute: minute)
        case .everyHour: return .hourly(minute: 0)
        case .every30Minutes: return .everyNMinutes(minutes: 30)
        case .firstOfMonth: return .monthly(dayOfMonth: 1, hour: hour, minute: minute)
        case .custom: return nil
        }
    }

    /// The day word: "Every weekday", "Every Monday", "Every hour".
    static func dayLabel(_ choice: DayChoice, style: Style = .current) -> String {
        switch choice {
        case .everyDay: return L("Every day")
        case .weekdays: return L("Every weekday")
        case .weekday(let day): return L("Every \(style.weekdayName(day))")
        case .everyHour: return L("Every hour")
        case .every30Minutes: return L("Every 30 minutes")
        case .firstOfMonth: return L("On the 1st of the month")
        case .custom: return L("On a custom schedule")
        }
    }

    // MARK: Words

    /// The watched folder's last path component.
    static func folderName(_ folder: FolderSourceConfig) -> String {
        guard let path = folder.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return L("a folder")
        }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? path : name
    }

    /// The feed's host without `www.`.
    static func siteName(_ rss: RSSSourceConfig) -> String {
        guard let host = TriggerSourceURL.parse(rss.url)?.host, !host.isEmpty else { return L("a site") }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The app a provider webhook stands for; nil for a generic one.
    static func providerName(_ provider: WebhookProvider) -> String? {
        switch provider {
        case .generic: return nil
        case .github: return "GitHub"
        case .stripe: return "Stripe"
        case .slack: return "Slack"
        case .shopify: return "Shopify"
        case .twilio: return "Twilio"
        case .microsoftGraph: return "Microsoft 365"
        case .facebook: return "Meta"
        case .sns: return "Amazon SNS"
        }
    }

    /// "Mondays" … "Sundays", for "Fridays at 4:00 PM".
    static func pluralWeekday(_ dayOfWeek: Int) -> String {
        switch max(1, min(7, dayOfWeek)) {
        case 1: return L("Sundays")
        case 2: return L("Mondays")
        case 3: return L("Tuesdays")
        case 4: return L("Wednesdays")
        case 5: return L("Thursdays")
        case 6: return L("Fridays")
        default: return L("Saturdays")
        }
    }
}
