//
//  CalendarService.swift
//  osaurus
//
//  EventKit-backed Calendar access for the built-in `calendar_*` tools.
//  Returns plain value types so the tools are unit-testable against a fake
//  and never touch `EKEvent` directly. All EventKit work runs on the
//  shared serial `AppleServiceQueue` (EventKit objects are not Sendable and
//  its status API is a synchronous XPC round-trip).
//

import EventKit
import Foundation

// MARK: - Models

struct CalendarInfo: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let account: String
    let color: String?
    let isEditable: Bool
    let isDefault: Bool
    let isSubscribed: Bool
    let type: String
}

struct CalendarAttendee: Codable, Equatable, Sendable {
    let name: String?
    let email: String?
    let status: String
    let isCurrentUser: Bool
}

struct CalendarAlarm: Codable, Equatable, Sendable {
    /// Minutes before the event start (positive = before).
    let minutesBefore: Int?
    let absoluteDate: Date?
}

struct CalendarRecurrence: Codable, Equatable, Sendable {
    let frequency: String
    let interval: Int
    let daysOfWeek: [String]?
    let endDate: Date?
    let occurrenceCount: Int?
}

struct CalendarEventInfo: Codable, Equatable, Sendable {
    let id: String
    let calendarId: String
    let calendarTitle: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let url: String?
    let status: String
    let availability: String
    let organizer: String?
    let attendees: [CalendarAttendee]
    let alarms: [CalendarAlarm]
    let recurrence: CalendarRecurrence?
    let isRecurring: Bool
    let isDetached: Bool
    let lastModified: Date?
    let openURL: String
}

struct CalendarEventDraft: Sendable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarId: String?
    var location: String?
    var notes: String?
    var url: String?
    var alarmsMinutesBefore: [Int]?
    var recurrence: CalendarRecurrence?
    var availability: String?
}

struct CalendarEventPatch: Sendable {
    var title: String??
    var start: Date?
    var end: Date?
    var isAllDay: Bool?
    var calendarId: String?
    var location: String??
    var notes: String??
    var url: String??
    var alarmsMinutesBefore: [Int]??
    var recurrence: CalendarRecurrence??
    var availability: String?

    var isEmpty: Bool {
        title == nil && start == nil && end == nil && isAllDay == nil && calendarId == nil && location == nil
            && notes == nil && url == nil && alarmsMinutesBefore == nil && recurrence == nil && availability == nil
    }
}

/// Raw values match the tool-facing `span` enum so input and output agree.
enum CalendarEditSpan: String, Sendable {
    case thisEvent = "this_event"
    case futureEvents = "future_events"
}

struct CalendarEventQuery: Sendable {
    var start: Date
    var end: Date
    var calendarIds: [String]?
    var query: String?
    var includeAllDay: Bool
}

// MARK: - Protocol

protocol CalendarServicing: Sendable {
    func calendars() async throws -> [CalendarInfo]
    func events(_ query: CalendarEventQuery) async throws -> [CalendarEventInfo]
    func event(id: String, occurrenceStart: Date?) async throws -> CalendarEventInfo
    func create(_ draft: CalendarEventDraft) async throws -> CalendarEventInfo
    func update(id: String, occurrenceStart: Date?, span: CalendarEditSpan, patch: CalendarEventPatch)
        async throws -> CalendarEventInfo
    func delete(id: String, occurrenceStart: Date?, span: CalendarEditSpan) async throws -> CalendarEventInfo
}

// MARK: - EventKit implementation

final class EventKitCalendarService: CalendarServicing, @unchecked Sendable {
    /// Confined to `AppleServiceQueue`; the class is `@unchecked Sendable`
    /// because every access happens on that serial queue. Created on first
    /// use: `EKEventStore()` opens an XPC session to the calendar daemon,
    /// which must not happen at tool registration (app launch / test boot).
    nonisolated(unsafe) private lazy var store = EKEventStore()

    private func requireAccess() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw AppleToolError.permissionDenied(.calendar)
        }
    }

    func calendars() async throws -> [CalendarInfo] {
        try await AppleServiceQueue.run { [self] in
            let store = self.store
            try self.requireAccess()
            let defaultId = store.defaultCalendarForNewEvents?.calendarIdentifier
            return store.calendars(for: .event)
                .map { Self.info($0, defaultId: defaultId) }
                .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        }
    }

    func events(_ query: CalendarEventQuery) async throws -> [CalendarEventInfo] {
        try await AppleServiceQueue.run { [self] in
            let store = self.store
            try self.requireAccess()
            let calendars = try self.resolveCalendars(query.calendarIds)
            // EventKit caps a single predicate at four years.
            let maxEnd = Calendar.current.date(byAdding: .year, value: 4, to: query.start) ?? query.end
            let end = min(query.end, maxEnd)
            guard end > query.start else {
                throw AppleToolError.invalidArgs("`end` must be after `start`.", field: "end")
            }
            let predicate = store.predicateForEvents(withStart: query.start, end: end, calendars: calendars)
            var events = store.events(matching: predicate)
            if !query.includeAllDay { events = events.filter { !$0.isAllDay } }
            if let q = query.query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
                events = events.filter {
                    AppleServiceSupport.matches($0.title, query: q)
                        || AppleServiceSupport.matches($0.location, query: q)
                        || AppleServiceSupport.matches($0.notes, query: q)
                }
            }
            events.sort { $0.startDate < $1.startDate }
            return events.map(Self.info)
        }
    }

    func event(id: String, occurrenceStart: Date?) async throws -> CalendarEventInfo {
        try await AppleServiceQueue.run {
            try self.requireAccess()
            return Self.info(try self.fetch(id: id, occurrenceStart: occurrenceStart))
        }
    }

    func create(_ draft: CalendarEventDraft) async throws -> CalendarEventInfo {
        try await AppleServiceQueue.run { [self] in
            let store = self.store
            try self.requireAccess()
            let event = EKEvent(eventStore: store)
            if let calendarId = draft.calendarId {
                event.calendar = try self.resolveCalendar(calendarId)
            } else if let defaultCalendar = store.defaultCalendarForNewEvents {
                event.calendar = defaultCalendar
            } else if let first = store.calendars(for: .event).first(where: { $0.allowsContentModifications }) {
                event.calendar = first
            } else {
                throw AppleToolError.unavailable("No writable calendar is available in Calendar.")
            }
            guard event.calendar.allowsContentModifications else {
                throw AppleToolError.invalidArgs(
                    "Calendar `\(event.calendar.title)` is read-only. Pick an editable calendar from `calendar_list`.",
                    field: "calendar"
                )
            }
            event.title = draft.title
            event.isAllDay = draft.isAllDay
            event.startDate = draft.start
            event.endDate = draft.end
            event.location = draft.location
            event.notes = draft.notes
            event.url = draft.url.flatMap(URL.init(string:))
            if let alarms = draft.alarmsMinutesBefore {
                event.alarms = alarms.map { EKAlarm(relativeOffset: TimeInterval(-$0 * 60)) }
            }
            if let recurrence = draft.recurrence {
                event.recurrenceRules = [try Self.rule(from: recurrence)]
            }
            if let availability = draft.availability {
                event.availability = try Self.availability(from: availability)
            }
            try self.save(event, span: .thisEvent)
            return Self.info(event)
        }
    }

    func update(
        id: String, occurrenceStart: Date?, span: CalendarEditSpan, patch: CalendarEventPatch
    ) async throws -> CalendarEventInfo {
        try await AppleServiceQueue.run {
            try self.requireAccess()
            let event = try self.fetch(id: id, occurrenceStart: occurrenceStart)
            guard event.calendar.allowsContentModifications else {
                throw AppleToolError.invalidArgs(
                    "Event `\(event.title ?? id)` is in the read-only calendar `\(event.calendar.title)`."
                )
            }
            if let title = patch.title, let title { event.title = title }
            if let isAllDay = patch.isAllDay { event.isAllDay = isAllDay }
            if let start = patch.start {
                // Keep the duration when only the start moves.
                let duration = event.endDate.timeIntervalSince(event.startDate)
                event.startDate = start
                if patch.end == nil { event.endDate = start.addingTimeInterval(duration) }
            }
            if let end = patch.end { event.endDate = end }
            guard event.endDate >= event.startDate else {
                throw AppleToolError.invalidArgs("`end` must not be before `start`.", field: "end")
            }
            if let calendarId = patch.calendarId { event.calendar = try self.resolveCalendar(calendarId) }
            if let location = patch.location { event.location = location }
            if let notes = patch.notes { event.notes = notes }
            if let url = patch.url { event.url = url.flatMap(URL.init(string:)) }
            if let alarms = patch.alarmsMinutesBefore {
                event.alarms = alarms?.map { EKAlarm(relativeOffset: TimeInterval(-$0 * 60)) }
            }
            if let recurrence = patch.recurrence {
                event.recurrenceRules = try recurrence.map { [try Self.rule(from: $0)] }
            }
            if let availability = patch.availability {
                event.availability = try Self.availability(from: availability)
            }
            try self.save(event, span: span == .futureEvents ? .futureEvents : .thisEvent)
            return Self.info(event)
        }
    }

    func delete(id: String, occurrenceStart: Date?, span: CalendarEditSpan) async throws -> CalendarEventInfo {
        try await AppleServiceQueue.run { [self] in
            let store = self.store
            try self.requireAccess()
            let event = try self.fetch(id: id, occurrenceStart: occurrenceStart)
            let snapshot = Self.info(event)
            do {
                try store.remove(event, span: span == .futureEvents ? .futureEvents : .thisEvent, commit: true)
            } catch {
                throw AppleToolError.execution("Calendar refused to delete the event: \(error.localizedDescription)")
            }
            return snapshot
        }
    }

    // MARK: Helpers (queue-confined)

    private func save(_ event: EKEvent, span: EKSpan) throws {
        do {
            try store.save(event, span: span, commit: true)
        } catch {
            throw AppleToolError.execution("Calendar refused to save the event: \(error.localizedDescription)")
        }
    }

    private func resolveCalendar(_ idOrTitle: String) throws -> EKCalendar {
        let all = store.calendars(for: .event)
        if let byId = all.first(where: { $0.calendarIdentifier == idOrTitle }) { return byId }
        let matches = all.filter { $0.title.compare(idOrTitle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1, let writable = matches.first(where: { $0.allowsContentModifications }) { return writable }
        throw AppleToolError.notFound(
            "No calendar with id or title `\(idOrTitle)`. Call `calendar_list` and pass one of its `id` values."
        )
    }

    private func resolveCalendars(_ ids: [String]?) throws -> [EKCalendar]? {
        guard let ids, !ids.isEmpty else { return nil }
        return try ids.map(resolveCalendar)
    }

    /// Resolve an event id to the right `EKEvent`. For recurring events,
    /// `occurrenceStart` selects the occurrence (matched within the same
    /// local day); without it the master/first occurrence is returned.
    private func fetch(id: String, occurrenceStart: Date?) throws -> EKEvent {
        guard let base = store.event(withIdentifier: id) else {
            throw AppleToolError.notFound(
                "No event with id `\(id)`. Call `calendar_events` and pass one of its `id` values."
            )
        }
        guard let occurrenceStart, base.hasRecurrenceRules || base.isDetached else { return base }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: occurrenceStart)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? occurrenceStart.addingTimeInterval(86400)
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: [base.calendar])
        let candidates = store.events(matching: predicate).filter { $0.eventIdentifier == id }
        if let exact = candidates.first(where: { abs($0.startDate.timeIntervalSince(occurrenceStart)) < 60 }) {
            return exact
        }
        if let sameDay = candidates.first { return sameDay }
        throw AppleToolError.notFound(
            "Event `\(base.title ?? id)` has no occurrence starting \(AppleDateParsing.format(occurrenceStart)). "
                + "Use the `start` of an occurrence returned by `calendar_events`."
        )
    }

    // MARK: Mapping

    fileprivate static func info(_ calendar: EKCalendar, defaultId: String?) -> CalendarInfo {
        CalendarInfo(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            account: calendar.source?.title ?? "",
            color: AppleServiceSupport.hexString(calendar.cgColor),
            isEditable: calendar.allowsContentModifications,
            isDefault: calendar.calendarIdentifier == defaultId,
            isSubscribed: calendar.type == .subscription,
            type: Self.typeName(calendar.type)
        )
    }

    fileprivate static func info(_ event: EKEvent) -> CalendarEventInfo {
        CalendarEventInfo(
            id: event.eventIdentifier ?? "",
            calendarId: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location.flatMap { $0.isEmpty ? nil : $0 },
            notes: event.notes.flatMap { $0.isEmpty ? nil : $0 },
            url: event.url?.absoluteString,
            status: Self.statusName(event.status),
            availability: Self.availabilityName(event.availability),
            organizer: event.organizer?.name,
            attendees: (event.attendees ?? []).map {
                CalendarAttendee(
                    name: $0.name,
                    email: Self.email(from: $0.url),
                    status: Self.participantStatusName($0.participantStatus),
                    isCurrentUser: $0.isCurrentUser
                )
            },
            alarms: (event.alarms ?? []).map {
                CalendarAlarm(
                    minutesBefore: $0.absoluteDate == nil ? Int((-$0.relativeOffset / 60).rounded()) : nil,
                    absoluteDate: $0.absoluteDate
                )
            },
            recurrence: event.recurrenceRules?.first.map(Self.recurrence),
            isRecurring: event.hasRecurrenceRules,
            isDetached: event.isDetached,
            lastModified: event.lastModifiedDate,
            openURL: "ical://ekevent/\(event.eventIdentifier ?? "")"
        )
    }

    private static func email(from url: URL?) -> String? {
        guard let url else { return nil }
        if url.scheme?.lowercased() == "mailto" {
            return url.absoluteString.dropFirst("mailto:".count).description
        }
        return nil
    }

    static func recurrence(_ rule: EKRecurrenceRule) -> CalendarRecurrence {
        let frequency: String
        switch rule.frequency {
        case .daily: frequency = "daily"
        case .weekly: frequency = "weekly"
        case .monthly: frequency = "monthly"
        case .yearly: frequency = "yearly"
        @unknown default: frequency = "unknown"
        }
        let days = rule.daysOfTheWeek?.map { Self.weekdayName($0.dayOfTheWeek) }
        return CalendarRecurrence(
            frequency: frequency,
            interval: rule.interval,
            daysOfWeek: (days?.isEmpty ?? true) ? nil : days,
            endDate: rule.recurrenceEnd?.endDate,
            occurrenceCount: rule.recurrenceEnd.flatMap { $0.occurrenceCount == 0 ? nil : $0.occurrenceCount }
        )
    }

    static func rule(from recurrence: CalendarRecurrence) throws -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch recurrence.frequency.lowercased() {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default:
            throw AppleToolError.invalidArgs(
                "recurrence.frequency must be one of: daily, weekly, monthly, yearly.",
                field: "recurrence.frequency"
            )
        }
        let days = try recurrence.daysOfWeek?.map { name -> EKRecurrenceDayOfWeek in
            guard let weekday = Self.weekday(named: name) else {
                throw AppleToolError.invalidArgs(
                    "recurrence.days_of_week entries must be weekday names (monday … sunday).",
                    field: "recurrence.days_of_week"
                )
            }
            return EKRecurrenceDayOfWeek(weekday)
        }
        var end: EKRecurrenceEnd?
        if let endDate = recurrence.endDate {
            end = EKRecurrenceEnd(end: endDate)
        } else if let count = recurrence.occurrenceCount, count > 0 {
            end = EKRecurrenceEnd(occurrenceCount: count)
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: max(1, recurrence.interval),
            daysOfTheWeek: (days?.isEmpty ?? true) ? nil : days,
            daysOfTheMonth: nil,
            monthsOfTheYear: nil,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: nil,
            end: end
        )
    }

    static func availability(from raw: String) throws -> EKEventAvailability {
        switch raw.lowercased() {
        case "busy": return .busy
        case "free": return .free
        case "tentative": return .tentative
        case "unavailable": return .unavailable
        default:
            throw AppleToolError.invalidArgs(
                "`availability` must be one of: busy, free, tentative, unavailable.", field: "availability"
            )
        }
    }

    private static func availabilityName(_ value: EKEventAvailability) -> String {
        switch value {
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        case .notSupported: return "not_supported"
        @unknown default: return "unknown"
        }
    }

    private static func statusName(_ value: EKEventStatus) -> String {
        switch value {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "unknown"
        }
    }

    private static func participantStatusName(_ value: EKParticipantStatus) -> String {
        switch value {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "in_process"
        @unknown default: return "unknown"
        }
    }

    private static func typeName(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "caldav"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }

    static func weekdayName(_ weekday: EKWeekday) -> String {
        switch weekday {
        case .sunday: return "sunday"
        case .monday: return "monday"
        case .tuesday: return "tuesday"
        case .wednesday: return "wednesday"
        case .thursday: return "thursday"
        case .friday: return "friday"
        case .saturday: return "saturday"
        @unknown default: return "unknown"
        }
    }

    static func weekday(named name: String) -> EKWeekday? {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "sunday", "sun", "su": return .sunday
        case "monday", "mon", "mo": return .monday
        case "tuesday", "tue", "tu": return .tuesday
        case "wednesday", "wed", "we": return .wednesday
        case "thursday", "thu", "th": return .thursday
        case "friday", "fri", "fr": return .friday
        case "saturday", "sat", "sa": return .saturday
        default: return nil
        }
    }
}
