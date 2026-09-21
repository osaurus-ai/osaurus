//
//  EventKitContractTests.swift
//  OsaurusCoreTests — AppleApps
//
//  Calendar / Reminders contracts that do not need a real EKEventStore:
//  all-day normalization (inclusive end, DST-safe), alarm clamping, `null`
//  clears, the recurring-update default span, the four-year clamp report,
//  and percent-encoded deep links.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Apple tools: EventKit contracts")
struct EventKitContractTests {

    private func result(_ raw: String) throws -> [String: Any] {
        let env = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect(env["ok"] as? Bool == true, "expected success envelope, got \(raw)")
        return try #require(env["result"] as? [String: Any])
    }

    private func envelope(_ raw: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    @Test("all-day normalization is inclusive: same-day, bare next-day midnight and 23:59:59 all mean one day")
    func allDayNormalization() {
        let start = day(2026, 9, 19)
        let (s1, e1) = EventKitCalendarService.normalizeAllDay(start: start, end: start, calendar: cal)
        #expect(s1 == start)
        #expect(e1 == day(2026, 9, 19, 23, 59, 59))

        let (_, e2) = EventKitCalendarService.normalizeAllDay(start: start, end: day(2026, 9, 20), calendar: cal)
        #expect(e2 == e1, "an exclusive next-day-midnight end is the same one-day event")

        let (_, e3) = EventKitCalendarService.normalizeAllDay(start: start, end: day(2026, 9, 19, 23, 59, 59), calendar: cal)
        #expect(e3 == e1)

        // Two days: end on the 20th (any instant on that day).
        let (_, e4) = EventKitCalendarService.normalizeAllDay(start: start, end: day(2026, 9, 20, 9), calendar: cal)
        #expect(e4 == day(2026, 9, 20, 23, 59, 59))

        // End before start collapses to one day rather than inverting.
        let (_, e5) = EventKitCalendarService.normalizeAllDay(start: start, end: day(2026, 9, 1), calendar: cal)
        #expect(e5 == e1)
    }

    @Test("all-day normalization across a DST change still lands on 23:59:59 of the last day")
    func allDayAcrossDST() {
        // US DST ends Nov 1 2026 (25-hour day in Los Angeles).
        let start = day(2026, 10, 31)
        let (_, end) = EventKitCalendarService.normalizeAllDay(start: start, end: day(2026, 11, 2), calendar: cal)
        #expect(end == day(2026, 11, 1, 23, 59, 59))
    }

    @Test("alarm minutes are clamped to 0…4 weeks and never trap on huge values")
    func alarmClamp() {
        #expect(AppleAlarms.clampMinutes(-5) == 0)
        #expect(AppleAlarms.clampMinutes(10) == 10)
        #expect(AppleAlarms.clampMinutes(Int.max) == AppleAlarms.maxMinutesBefore)
        #expect(AppleAlarms.relative(minutesBefore: Int.max).relativeOffset == -Double(AppleAlarms.maxMinutesBefore) * 60)
        #expect(AppleAlarms.relative(minutesBefore: 15).relativeOffset == -900)
        #expect(AppleAlarms.clamped([10, Int.max, -1]) == [Int.max, -1])
        #expect(CalendarArgs.alarmWarning([10]) == nil)
        #expect(CalendarArgs.alarmWarning([10, 999_999_999])?.contains("clamped") == true)
    }

    @Test("deep-link ids are percent-encoded per path component")
    func deepLinkEncoding() {
        #expect(AppleServiceSupport.pathEncoded("ABC-123") == "ABC-123")
        #expect(AppleServiceSupport.pathEncoded("A1B2:C3D4:ABPerson") == "A1B2:C3D4:ABPerson", "colons stay literal")
        #expect(AppleServiceSupport.pathEncoded("x/y z?#%") == "x%2Fy%20z%3F%23%25")
        #expect(URL(string: "ical://ekevent/\(AppleServiceSupport.pathEncoded("x/y z"))") != nil)
    }

    @Test("Calendar/Reminders nullable clear fields accept JSON null and reject as-string type mismatches")
    func nullableSchema() throws {
        let update = CalendarUpdateEventTool(service: NullClearCalendarService())
        let schema = try #require(update.parameters)
        guard case .object(let root) = schema, case .object(let props)? = root["properties"],
            case .object(let location)? = props["location"]
        else { Issue.record("schema shape"); return }
        #expect(location["nullable"] == .bool(true))
        #expect(location["type"] == .string("string"))
    }

    @Test("calendar_update_event: null clears location; a recurring event without occurrence_start is refused like delete")
    func updateNullClearAndRecurringRefusal() async throws {
        let service = NullClearCalendarService()
        let tool = CalendarUpdateEventTool(service: service)
        let payload = try result(await tool.execute(argumentsJSON: #"{"id":"e1","location":null,"notes":"keep"}"#))
        #expect(payload["updated"] as? Bool == true)
        let patch = try #require(service.lastPatch)
        #expect(patch.location == .some(nil), "null must arrive as an explicit clear")
        #expect(patch.notes == .some("keep"))
        #expect(service.lastSpan == .thisEvent)

        // Recurring master, no occurrence_start → refused; nothing written.
        // "Move my standup tomorrow" must never silently rewrite the series
        // (or detach only the first occurrence).
        service.recurring = true
        let before = service.updateCount
        let env = try envelope(await tool.execute(argumentsJSON: #"{"id":"e1","title":"Renamed"}"#))
        #expect(env["ok"] as? Bool == false)
        #expect(env["kind"] as? String == "invalid_args")
        #expect(env["field"] as? String == "occurrence_start")
        #expect(service.updateCount == before)

        // An explicit `span: future_events` alone is not enough either — the
        // occurrence anchors the edit exactly as it does for delete.
        let env2 = try envelope(await tool.execute(argumentsJSON: #"{"id":"e1","title":"Renamed","span":"future_events"}"#))
        #expect(env2["kind"] as? String == "invalid_args")
        #expect(service.updateCount == before)

        // With the occurrence, span is honoured (default this_event).
        _ = try result(await tool.execute(argumentsJSON: #"{"id":"e1","title":"One","occurrence_start":"2026-09-19T10:00"}"#))
        #expect(service.lastSpan == .thisEvent)
        _ = try result(await tool.execute(argumentsJSON: #"{"id":"e1","title":"All","span":"future_events","occurrence_start":"2026-09-19T10:00"}"#))
        #expect(service.lastSpan == .futureEvents)
        #expect(service.updateCount == before + 2)
    }

    @Test("calendar_events reports the four-year clamp as a warning and in range.end_clamped")
    func fourYearClampReport() async throws {
        let service = NullClearCalendarService()
        service.clamp = true
        let tool = CalendarEventsTool(service: service)
        let raw = try await tool.execute(argumentsJSON: #"{"start":"2026-01-01","end":"2036-01-01"}"#)
        let env = try envelope(raw)
        let payload = try #require(env["result"] as? [String: Any])
        let range = try #require(payload["range"] as? [String: Any])
        #expect(range["end_clamped"] as? Bool == true)
        #expect((env["warnings"] as? [String])?.first?.contains("four years") == true)
    }

    @Test("calendar_create_event all-day: bare end date is the inclusive last day")
    func createAllDayInclusive() async throws {
        let service = NullClearCalendarService()
        let tool = CalendarCreateEventTool(service: service)
        _ = try result(await tool.execute(argumentsJSON: #"{"title":"Trip","start":"2026-09-19","end":"2026-09-20"}"#))
        let draft = try #require(service.lastDraft)
        #expect(draft.isAllDay)
        let c = Calendar.current
        #expect(c.startOfDay(for: draft.start) == draft.start)
        #expect(c.component(.day, from: draft.end) == 20, "end stays on the 20th (inclusive), not the 21st")
        #expect(c.component(.hour, from: draft.end) == 23)
        #expect(c.component(.second, from: draft.end) == 59)

        _ = try result(await tool.execute(argumentsJSON: #"{"title":"Day","start":"2026-09-19"}"#))
        let single = try #require(service.lastDraft)
        #expect(c.component(.day, from: single.end) == 19)
        #expect(single.end > single.start)
    }

    @Test("reminders_update: null clears due; alarms without due and recurrence without due are invalid_args at the tool")
    func remindersUpdateContracts() async throws {
        let service = FakeRemindersServiceForContracts()
        let tool = RemindersUpdateTool(service: service)
        _ = try result(await tool.execute(argumentsJSON: #"{"id":"r1","due":null}"#))
        #expect(service.lastPatch?.due == .some(nil))

        let create = RemindersCreateTool(service: service)
        let noDueAlarm = try envelope(await create.execute(argumentsJSON: #"{"title":"x","alarms_minutes_before":[10]}"#))
        #expect(noDueAlarm["kind"] as? String == "invalid_args")
        #expect(noDueAlarm["field"] as? String == "alarms_minutes_before")
        let noDueRecurrence = try envelope(await create.execute(argumentsJSON: #"{"title":"x","recurrence":{"frequency":"daily"}}"#))
        #expect(noDueRecurrence["kind"] as? String == "invalid_args")
        #expect(noDueRecurrence["field"] as? String == "recurrence")

        // Priority copy no longer advertises 0–9 while the enum forbids it.
        let schema = try #require(create.parameters)
        guard case .object(let root) = schema, case .object(let props)? = root["properties"],
            case .object(let priority)? = props["priority"], case .string(let desc)? = priority["description"]
        else { Issue.record("schema shape"); return }
        #expect(!desc.contains("0"))
    }
}

// MARK: - Fakes

private final class NullClearCalendarService: CalendarServicing, @unchecked Sendable {
    var recurring = false
    var clamp = false
    private(set) var lastPatch: CalendarEventPatch?
    private(set) var lastSpan: CalendarEditSpan?
    private(set) var lastDraft: CalendarEventDraft?
    private(set) var updateCount = 0

    private func event(_ id: String) -> CalendarEventInfo {
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        return CalendarEventInfo(
            id: id, calendarId: "cal-1", calendarTitle: "Work", title: "Weekly", start: start, end: start.addingTimeInterval(1800),
            isAllDay: false, allDayDates: nil, location: "Room", notes: nil, url: nil, status: "confirmed", availability: "busy",
            organizer: nil, attendees: [], alarms: [], recurrence: nil, isRecurring: recurring, isDetached: false,
            lastModified: nil, openURL: "ical://ekevent/\(id)")
    }

    func calendars() async throws -> [CalendarInfo] { [] }
    func events(_ query: CalendarEventQuery) async throws -> CalendarEventsResult {
        let effective = clamp ? (Calendar.current.date(byAdding: .year, value: 4, to: query.start) ?? query.end) : query.end
        return CalendarEventsResult(events: [], effectiveEnd: min(effective, query.end), endWasClamped: clamp && effective < query.end)
    }
    func event(id: String, occurrenceStart: Date?) async throws -> CalendarEventInfo { event(id) }
    func create(_ draft: CalendarEventDraft) async throws -> CalendarEventInfo {
        lastDraft = draft
        return event("new")
    }
    func update(id: String, occurrenceStart: Date?, span: CalendarEditSpan, patch: CalendarEventPatch) async throws -> CalendarEventInfo {
        lastPatch = patch
        lastSpan = span
        updateCount += 1
        return event(id)
    }
    func delete(id: String, occurrenceStart: Date?, span: CalendarEditSpan) async throws -> CalendarEventInfo { event(id) }
}

private final class FakeRemindersServiceForContracts: RemindersServicing, @unchecked Sendable {
    private(set) var lastPatch: ReminderPatch?
    private func reminder(_ id: String) -> ReminderInfo {
        ReminderInfo(
            id: id, listId: "l1", listTitle: "Inbox", title: "x", notes: nil, url: nil, isCompleted: false, completionDate: nil,
            dueDate: nil, dueIsDateOnly: false, startDate: nil, priority: 0, priorityLabel: "none", alarms: [], recurrence: nil,
            lastModified: nil, openURL: "x-apple-reminderkit://REMCDReminder/\(id)")
    }
    func lists() async throws -> [ReminderListInfo] { [] }
    func reminders(_ query: ReminderQuery) async throws -> [ReminderInfo] { [] }
    func reminder(id: String) async throws -> ReminderInfo { reminder(id) }
    func create(_ draft: ReminderDraft) async throws -> ReminderInfo { reminder("new") }
    func update(id: String, patch: ReminderPatch) async throws -> ReminderInfo {
        lastPatch = patch
        return reminder(id)
    }
    func delete(id: String) async throws -> ReminderInfo { reminder(id) }
}
