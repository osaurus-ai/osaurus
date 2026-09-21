//
//  CalendarTools.swift
//  osaurus
//
//  Built-in `calendar_*` tools (per-agent opt-in via `AppleApp.calendar`).
//  Reads run automatically once the macOS Calendar permission is granted;
//  create/update pause for approval; delete asks on every call.
//

import AppKit
import Foundation

enum CalendarToolFactory {
    static func makeTools(service: CalendarServicing = EventKitCalendarService()) -> [OsaurusTool] {
        [
            CalendarListTool(service: service),
            CalendarEventsTool(service: service),
            CalendarCreateEventTool(service: service),
            CalendarUpdateEventTool(service: service),
            CalendarDeleteEventTool(service: service),
            CalendarOpenEventTool(service: service),
        ]
    }
}

// MARK: - Shared argument parsing

enum CalendarArgs {
    static func recurrence(_ args: [String: Any]) throws -> CalendarRecurrence? {
        guard let dict = try AppleArgs.object(args, "recurrence") else { return nil }
        let frequency = try AppleArgs.enumeration(
            dict, "frequency", allowed: ["daily", "weekly", "monthly", "yearly"]
        )
        guard let frequency else {
            throw AppleToolError.invalidArgs(
                "recurrence.frequency is required (daily | weekly | monthly | yearly).", field: "recurrence.frequency"
            )
        }
        let interval = try AppleArgs.int(dict, "interval") ?? 1
        let days = try AppleArgs.stringArray(dict, "days_of_week")
        let endDate = try AppleArgs.date(dict, "end_date")
        let count = try AppleArgs.int(dict, "occurrence_count")
        return CalendarRecurrence(
            frequency: frequency,
            interval: max(1, interval),
            daysOfWeek: (days?.isEmpty ?? true) ? nil : days,
            endDate: endDate?.exclusiveRangeEnd,
            occurrenceCount: endDate == nil ? count : nil
        )
    }

    static func alarms(_ args: [String: Any]) throws -> [Int]? {
        guard let raw = args["alarms_minutes_before"], !(raw is NSNull) else { return nil }
        if let arr = raw as? [Any] {
            return arr.compactMap { ArgumentCoercion.int($0) ?? ($0 as? Double).map { Int($0) } }
        }
        if let single = ArgumentCoercion.int(raw) { return [single] }
        throw AppleToolError.invalidArgs(
            "`alarms_minutes_before` must be an array of integers (minutes before the start).",
            field: "alarms_minutes_before"
        )
    }

    /// Explicit `span`, or nil when the caller did not pass one (the update
    /// tool then picks a default from the event's recurrence).
    static func span(_ args: [String: Any]) throws -> CalendarEditSpan? {
        guard let raw = try AppleArgs.enumeration(args, "span", allowed: ["this_event", "future_events"]) else { return nil }
        return raw == "future_events" ? .futureEvents : .thisEvent
    }

    /// Normalize an all-day event to EventKit's inclusive convention (see
    /// `EventKitCalendarService.normalizeAllDay`).
    static func normalizeAllDay(start: Date, end: Date) -> (Date, Date) {
        EventKitCalendarService.normalizeAllDay(start: start, end: end)
    }

    /// Warning text when any alert offset had to be clamped.
    static func alarmWarning(_ minutes: [Int]?) -> String? {
        guard let minutes else { return nil }
        let clamped = AppleAlarms.clamped(minutes)
        guard !clamped.isEmpty else { return nil }
        return "alarms_minutes_before values \(clamped) were clamped to 0…\(AppleAlarms.maxMinutesBefore) minutes (4 weeks)."
    }

    /// Bare-date strings for an all-day range, for the tool payload.
    static func allDayRange(start: Date, end: Date) -> AppleDayRange {
        AppleDayRange(start: AppleDateParsing.formatDateOnly(start), end: AppleDateParsing.formatDateOnly(end))
    }
}

// MARK: - calendar_list

final class CalendarListTool: AppleToolBase, @unchecked Sendable {
    private let service: CalendarServicing

    init(service: CalendarServicing) {
        self.service = service
        super.init(
            app: .calendar,
            name: "calendar_list",
            description:
                "List the user's calendars (id, title, account, color, whether it is editable, the default for new events, or a read-only subscription). Call this before creating an event in a specific calendar.",
            parameters: AppleSchema.object([:]),
            isWrite: false
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let calendars = try await service.calendars()
        return AppleToolPayload(["calendars": calendars, "count": calendars.count])
    }
}

// MARK: - calendar_events

final class CalendarEventsTool: AppleToolBase, @unchecked Sendable {
    private let service: CalendarServicing
    static let defaultLimit = 50

    init(service: CalendarServicing) {
        self.service = service
        super.init(
            app: .calendar,
            name: "calendar_events",
            description:
                "List or search calendar events in a date range (defaults to now through the next 7 days). Returns each event's id, occurrence start/end, calendar, location, attendees, alarms, and recurrence. Use the returned `id` (and `start` for recurring events) with calendar_update_event / calendar_delete_event.",
            parameters: AppleSchema.object([
                "start": AppleSchema.date("Range start (default: now)."),
                "end": AppleSchema.date("Range end (default: 7 days after start)."),
                "calendars": AppleSchema.stringArray("Restrict to these calendar ids or titles (from calendar_list)."),
                "query": AppleSchema.string("Case-insensitive text to match in the title, location, or notes."),
                "include_all_day": AppleSchema.boolean("Include all-day events (default true)."),
                "limit": AppleSchema.limit(default: Self.defaultLimit),
            ]),
            isWrite: false
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let now = Date()
        let start = try AppleArgs.date(args, "start")?.date ?? now
        let end: Date
        if let parsedEnd = try AppleArgs.date(args, "end") {
            end = parsedEnd.exclusiveRangeEnd
        } else {
            end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86400)
        }
        guard end > start else {
            throw AppleToolError.invalidArgs("`end` must be after `start`.", field: "end")
        }
        let limit = try AppleArgs.limit(args, default: Self.defaultLimit)
        let query = CalendarEventQuery(
            start: start,
            end: end,
            calendarIds: try AppleArgs.stringArray(args, "calendars"),
            query: try AppleArgs.string(args, "query"),
            includeAllDay: try AppleArgs.bool(args, "include_all_day") ?? true
        )
        let result = try await service.events(query)
        let page = AppleServiceSupport.page(result.events, limit: limit)
        var warnings: [String] = []
        if result.endWasClamped {
            warnings.append(
                "Calendar searches cover at most four years per call; the range was searched through \(AppleDateParsing.format(result.effectiveEnd)). Call again with a later `start` for the rest.")
        }
        return AppleToolPayload(
            [
                "events": page.items,
                "count": page.items.count,
                "total_in_range": page.total,
                "truncated": page.truncated,
                "range": ["start": start, "end": result.effectiveEnd, "end_clamped": result.endWasClamped],
            ], warnings: warnings)
    }
}

// MARK: - calendar_create_event

final class CalendarCreateEventTool: AppleToolBase, @unchecked Sendable {
    private let service: CalendarServicing

    init(service: CalendarServicing) {
        self.service = service
        super.init(
            app: .calendar,
            name: "calendar_create_event",
            description:
                "Create a calendar event. Requires `title` and `start`; `end` defaults to one hour later (or the same day for all-day events). For all-day events `end` is the LAST day (inclusive): start 2026-09-19, end 2026-09-19 is a one-day event. Optionally set the calendar, location, notes, URL, alarms, availability, and a repeat rule. Returns the created event including its id.",
            parameters: AppleSchema.object(
                [
                    "title": AppleSchema.string("Event title."),
                    "start": AppleSchema.date("Start."),
                    "end": AppleSchema.date("End (default: start + 1 hour; all-day: same day). For all-day events a bare date is the last day, inclusive."),
                    "all_day": AppleSchema.boolean("All-day event (default false; true when `start` is a bare date)."),
                    "calendar": AppleSchema.string("Calendar id or title (from calendar_list). Default: the user's default calendar."),
                    "location": AppleSchema.string("Location text."),
                    "notes": AppleSchema.string("Notes / description."),
                    "url": AppleSchema.string("Related URL."),
                    "alarms_minutes_before": AppleSchema.integerArray("Alerts, in minutes before the start (e.g. [10, 60])."),
                    "availability": AppleSchema.string("Show as.", enum: ["busy", "free", "tentative", "unavailable"]),
                    "recurrence": AppleSchema.recurrence,
                ],
                required: ["title", "start"]
            ),
            isWrite: true
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let title = try AppleArgs.requiredString(args, "title", expected: "the event title")
        guard let startParsed = try AppleArgs.date(args, "start", required: true) else {
            throw AppleToolError.invalidArgs("Missing required argument `start`.", field: "start")
        }
        let endParsed = try AppleArgs.date(args, "end")
        let allDay = try AppleArgs.bool(args, "all_day") ?? startParsed.isDateOnly
        var start = startParsed.date
        var end: Date
        if let endParsed {
            if allDay {
                // Inclusive last day: a bare date means the whole of that day
                // (its 23:59:59); an explicit midnight instant is exclusive.
                end = endParsed.isDateOnly ? endParsed.exclusiveRangeEnd.addingTimeInterval(-1) : endParsed.date
            } else {
                end = endParsed.isDateOnly ? endParsed.exclusiveRangeEnd : endParsed.date
            }
        } else {
            end = allDay ? start : start.addingTimeInterval(3600)
        }
        if allDay {
            guard Calendar.current.startOfDay(for: end) >= Calendar.current.startOfDay(for: start) else {
                throw AppleToolError.invalidArgs("`end` must not be before `start`.", field: "end")
            }
            (start, end) = CalendarArgs.normalizeAllDay(start: start, end: end)
        }
        guard end > start else {
            throw AppleToolError.invalidArgs("`end` must be after `start`.", field: "end")
        }
        let draft = CalendarEventDraft(
            title: title,
            start: start,
            end: end,
            isAllDay: allDay,
            calendarId: try AppleArgs.string(args, "calendar"),
            location: try AppleArgs.string(args, "location"),
            notes: try AppleArgs.string(args, "notes"),
            url: try AppleArgs.string(args, "url"),
            alarmsMinutesBefore: try CalendarArgs.alarms(args),
            recurrence: try CalendarArgs.recurrence(args),
            availability: try AppleArgs.enumeration(
                args, "availability", allowed: ["busy", "free", "tentative", "unavailable"]
            )
        )
        let created = try await service.create(draft)
        return AppleToolPayload(
            ["event": created, "created": true],
            warnings: [CalendarArgs.alarmWarning(draft.alarmsMinutesBefore)].compactMap { $0 })
    }
}

// MARK: - calendar_update_event

final class CalendarUpdateEventTool: AppleToolBase, @unchecked Sendable {
    private let service: CalendarServicing

    init(service: CalendarServicing) {
        self.service = service
        super.init(
            app: .calendar,
            name: "calendar_update_event",
            description:
                "Update an existing event by `id` (from calendar_events). Only the supplied fields change; moving `start` alone keeps the duration. For a recurring event pass `occurrence_start` (the occurrence's `start`) and choose `span`: this_event or future_events (default this_event with an occurrence, future_events — the whole series — without one). Pass null for location/notes/url to clear them, or `clear_recurrence: true` to remove the repeat rule.",
            parameters: AppleSchema.object(
                [
                    "id": AppleSchema.string("Event id from calendar_events."),
                    "occurrence_start": AppleSchema.date("For recurring events: the start of the occurrence to edit."),
                    "span": AppleSchema.string("Which occurrences to change.", enum: ["this_event", "future_events"]),
                    "title": AppleSchema.string("New title."),
                    "start": AppleSchema.date("New start."),
                    "end": AppleSchema.date("New end."),
                    "all_day": AppleSchema.boolean("Make the event all-day (or not)."),
                    "calendar": AppleSchema.string("Move to this calendar (id or title)."),
                    "location": AppleSchema.nullableString("New location (null clears)."),
                    "notes": AppleSchema.nullableString("New notes (null clears)."),
                    "url": AppleSchema.nullableString("New URL (null clears)."),
                    "alarms_minutes_before": AppleSchema.integerArray("Replace alerts with these minutes-before values ([] removes all)."),
                    "availability": AppleSchema.string("Show as.", enum: ["busy", "free", "tentative", "unavailable"]),
                    "recurrence": AppleSchema.recurrence,
                    "clear_recurrence": AppleSchema.boolean("Remove the repeat rule."),
                ],
                required: ["id"]
            ),
            isWrite: true
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "an event id from calendar_events")
        let occurrenceStart = try AppleArgs.date(args, "occurrence_start")?.date
        let explicitSpan = try CalendarArgs.span(args)
        var patch = CalendarEventPatch()
        if let title = try AppleArgs.string(args, "title") { patch.title = .some(title) }
        if let start = try AppleArgs.date(args, "start") { patch.start = start.date }
        if let end = try AppleArgs.date(args, "end") {
            // A bare end date is inclusive: 23:59:59 of that day. The service's
            // all-day normalization keeps that instant; timed events get the
            // exclusive next-midnight bound as before.
            let allDayHint = try AppleArgs.bool(args, "all_day") == true
            patch.end = end.isDateOnly ? (allDayHint ? end.exclusiveRangeEnd.addingTimeInterval(-1) : end.exclusiveRangeEnd) : end.date
        }
        patch.isAllDay = try AppleArgs.bool(args, "all_day")
        patch.calendarId = try AppleArgs.string(args, "calendar")
        if args["location"] != nil { patch.location = .some(try AppleArgs.string(args, "location")) }
        if args["notes"] != nil { patch.notes = .some(try AppleArgs.string(args, "notes")) }
        if args["url"] != nil { patch.url = .some(try AppleArgs.string(args, "url")) }
        if args["alarms_minutes_before"] != nil { patch.alarmsMinutesBefore = .some(try CalendarArgs.alarms(args) ?? []) }
        patch.availability = try AppleArgs.enumeration(
            args, "availability", allowed: ["busy", "free", "tentative", "unavailable"]
        )
        if try AppleArgs.bool(args, "clear_recurrence") == true {
            patch.recurrence = .some(nil)
        } else if let recurrence = try CalendarArgs.recurrence(args) {
            patch.recurrence = .some(recurrence)
        }
        guard !patch.isEmpty else {
            throw AppleToolError.invalidArgs(
                "Nothing to update: pass at least one field (title, start, end, location, notes, url, alarms_minutes_before, availability, recurrence)."
            )
        }
        // Recurring event without an occurrence: the fetch returns the
        // master, and `this_event` would silently detach only the first
        // occurrence. Default to the whole series and say so.
        var span = explicitSpan ?? .thisEvent
        var warnings: [String] = []
        if explicitSpan == nil, occurrenceStart == nil {
            let existing = try await service.event(id: id, occurrenceStart: nil)
            if existing.isRecurring {
                span = .futureEvents
                warnings.append(
                    "`\(existing.title)` repeats and no `occurrence_start` was given, so the whole series was updated (span future_events). Pass `occurrence_start` and `span: this_event` to change one occurrence.")
            }
        }
        if let w = CalendarArgs.alarmWarning(patch.alarmsMinutesBefore ?? nil) { warnings.append(w) }
        let updated = try await service.update(id: id, occurrenceStart: occurrenceStart, span: span, patch: patch)
        return AppleToolPayload(["event": updated, "updated": true, "span": span.rawValue], warnings: warnings)
    }
}

// MARK: - calendar_delete_event

final class CalendarDeleteEventTool: AppleToolBase, PerCallApprovalTool, @unchecked Sendable {
    private let service: CalendarServicing

    init(service: CalendarServicing) {
        self.service = service
        super.init(
            app: .calendar,
            name: "calendar_delete_event",
            description:
                "Delete an event by `id`. For a recurring event you MUST pass `occurrence_start` and choose `span` (this_event deletes one occurrence; future_events deletes it and everything after). Irreversible; the user approves every call.",
            parameters: AppleSchema.object(
                [
                    "id": AppleSchema.string("Event id from calendar_events."),
                    "occurrence_start": AppleSchema.date("Required for recurring events: the start of the occurrence."),
                    "span": AppleSchema.string("Which occurrences to delete.", enum: ["this_event", "future_events"]),
                ],
                required: ["id"]
            ),
            isWrite: true
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "an event id from calendar_events")
        let occurrenceStart = try AppleArgs.date(args, "occurrence_start")?.date
        let span = try CalendarArgs.span(args) ?? .thisEvent
        let existing = try await service.event(id: id, occurrenceStart: occurrenceStart)
        if existing.isRecurring, occurrenceStart == nil {
            throw AppleToolError.invalidArgs(
                "`\(existing.title)` repeats. Pass `occurrence_start` (the occurrence's `start` from calendar_events) and `span` so the right occurrence(s) are deleted.",
                field: "occurrence_start"
            )
        }
        let deleted = try await service.delete(id: id, occurrenceStart: occurrenceStart, span: span)
        return AppleToolPayload(["event": deleted, "deleted": true, "span": span.rawValue])
    }
}

// MARK: - calendar_open_event

final class CalendarOpenEventTool: AppleToolBase, @unchecked Sendable {
    private let service: CalendarServicing

    init(service: CalendarServicing) {
        self.service = service
        super.init(
            app: .calendar,
            name: "calendar_open_event",
            description: "Open an event in the Calendar app by `id` so the user can see it.",
            parameters: AppleSchema.object(
                ["id": AppleSchema.string("Event id from calendar_events.")],
                required: ["id"]
            ),
            isWrite: false
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "an event id from calendar_events")
        let event = try await service.event(id: id, occurrenceStart: nil)
        guard let url = URL(string: event.openURL) else {
            throw AppleToolError.execution("Could not build a Calendar link for `\(id)`.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            throw AppleToolError.unavailable("Calendar could not be opened for event `\(event.title)`.", retryable: true)
        }
        return AppleToolPayload(["opened": true, "event": event])
    }
}
