//
//  AutomationPresets.swift
//  osaurus
//
//  One-click ways to start a workflow on its own: a few schedules, the
//  first marked Suggested when the workflow's name or summary matches a
//  rule below, and always "Pick a day and time…" last. The rules are one
//  table, first match wins; no model is asked.
//

import Foundation

enum AutomationPresets {
    enum Kind: Equatable, Sendable {
        /// Creates this schedule at once.
        case schedule(ScheduleFrequency)
        /// Watches a folder; the person picks it, so it is not one click.
        case folder(suggestedPath: String)
        /// Opens the workflow's page with a new schedule to set.
        case pickDayAndTime
    }

    struct Preset: Equatable, Identifiable, Sendable {
        let kind: Kind
        /// "Every weekday at 9:00 AM".
        let title: String
        let isSuggested: Bool
        var id: String {
            switch kind {
            case .schedule(let frequency): return "schedule:\(frequency)"
            case .folder(let path): return "folder:\(path)"
            case .pickDayAndTime: return "pick"
            }
        }
    }

    struct Rule: Sendable {
        let words: [String]
        let suggestion: Kind
    }

    /// Lowercased words in the name or summary, first match wins.
    static let rules: [Rule] = [
        Rule(words: ["morning"], suggestion: .schedule(ScheduleCronShape.weekdays(hour: 8, minute: 0).frequency)),
        Rule(
            words: ["end of day", "evening", "wrap"],
            suggestion: .schedule(ScheduleCronShape.weekdays(hour: 18, minute: 0).frequency)),
        Rule(words: ["weekly", "digest"], suggestion: .schedule(.weekly(dayOfWeek: 6, hour: 16, minute: 0))),
        Rule(words: ["download"], suggestion: .folder(suggestedPath: "~/Downloads")),
    ]

    static let defaultSchedules: [ScheduleFrequency] = [
        ScheduleCronShape.weekdays(hour: 9, minute: 0).frequency,
        .daily(hour: 9, minute: 0),
    ]

    static func suggestion(name: String, summary: String?) -> Kind? {
        let text = (name + " " + (summary ?? "")).lowercased()
        return rules.first { rule in rule.words.contains { text.contains($0) } }?.suggestion
    }

    /// Two presets and "Pick a day and time…".
    static func presets(name: String, summary: String?, style: AutomationSentence.Style = .current) -> [Preset] {
        var shown: [Preset] = []
        if let suggested = suggestion(name: name, summary: summary) {
            shown.append(Preset(kind: suggested, title: title(suggested, style: style), isSuggested: true))
        }
        for frequency in defaultSchedules where shown.count < 2 {
            let kind = Kind.schedule(frequency)
            if !shown.contains(where: { $0.kind == kind }) {
                shown.append(Preset(kind: kind, title: title(kind, style: style), isSuggested: false))
            }
        }
        return shown + [Preset(kind: .pickDayAndTime, title: title(.pickDayAndTime, style: style), isSuggested: false)]
    }

    static func title(_ kind: Kind, style: AutomationSentence.Style = .current) -> String {
        switch kind {
        case .schedule(let frequency): return scheduleTitle(frequency, style: style)
        case .folder(let path): return L("When a file shows up in \((path as NSString).lastPathComponent)")
        case .pickDayAndTime: return L("Pick a day and time…")
        }
    }

    /// "Every weekday at 9:00 AM"; a schedule the day menu can't say uses
    /// its sentence.
    static func scheduleTitle(_ frequency: ScheduleFrequency, style: AutomationSentence.Style = .current) -> String {
        let parts = AutomationSentence.scheduleParts(frequency)
        guard parts.day != .custom else {
            return AutomationSentence.capitalizedFirst(
                AutomationSentence.longSchedule(frequency, style: style), locale: style.locale)
        }
        let day = AutomationSentence.dayLabel(parts.day, style: style)
        guard parts.day.hasTime else { return day }
        return L("\(day) at \(style.time(hour: parts.hour, minute: parts.minute))")
    }

    /// "every weekday at 6:00 PM", for "Morning Brief will run …".
    static func schedulePhrase(_ frequency: ScheduleFrequency, style: AutomationSentence.Style = .current) -> String {
        let title = scheduleTitle(frequency, style: style)
        guard let first = title.first else { return title }
        return String(first).lowercased(with: style.locale) + title.dropFirst()
    }
}
