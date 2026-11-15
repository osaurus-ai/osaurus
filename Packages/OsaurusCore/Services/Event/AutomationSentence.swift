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
