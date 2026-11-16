//
//  RemindersService.swift
//  osaurus
//
//  EventKit-backed Reminders access for the built-in `reminders_*` tools.
//  Same shape as `CalendarService`: plain value types out, all EventKit work
//  confined to `AppleServiceQueue`.
//

import EventKit
import Foundation

// MARK: - Models

struct ReminderListInfo: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let account: String
    let color: String?
    let isEditable: Bool
    let isDefault: Bool
}

struct ReminderInfo: Codable, Equatable, Sendable {
    let id: String
    let listId: String
    let listTitle: String
    let title: String
    let notes: String?
    let url: String?
    let isCompleted: Bool
    let completionDate: Date?
    let dueDate: Date?
    let dueIsDateOnly: Bool
    let startDate: Date?
    /// 0 none, 1 high, 5 medium, 9 low (EventKit convention); surfaced as a word too.
    let priority: Int
    let priorityLabel: String
    let alarms: [CalendarAlarm]
    let recurrence: CalendarRecurrence?
    let lastModified: Date?
    let openURL: String
}

enum ReminderStatusFilter: String, Sendable {
    case incomplete
    case completed
    case all
}

struct ReminderQuery: Sendable {
    var listIds: [String]?
    var status: ReminderStatusFilter
    var dueAfter: Date?
    var dueBefore: Date?
    var query: String?
}

struct ReminderDraft: Sendable {
    var title: String
    var listId: String?
    var notes: String?
    var url: String?
    var due: AppleParsedDate?
    var priority: Int?
    var alarmsMinutesBefore: [Int]?
    var alarmAt: Date?
    var recurrence: CalendarRecurrence?
}

struct ReminderPatch: Sendable {
    var title: String?
    var listId: String?
    var notes: String??
    var url: String??
    var due: AppleParsedDate??
    var priority: Int?
    var alarmsMinutesBefore: [Int]??
    var recurrence: CalendarRecurrence??
    var isCompleted: Bool?

    var isEmpty: Bool {
        title == nil && listId == nil && notes == nil && url == nil && due == nil && priority == nil
            && alarmsMinutesBefore == nil && recurrence == nil && isCompleted == nil
    }
}

// MARK: - Protocol

protocol RemindersServicing: Sendable {
    func lists() async throws -> [ReminderListInfo]
    func reminders(_ query: ReminderQuery) async throws -> [ReminderInfo]
    func reminder(id: String) async throws -> ReminderInfo
    func create(_ draft: ReminderDraft) async throws -> ReminderInfo
    func update(id: String, patch: ReminderPatch) async throws -> ReminderInfo
    func delete(id: String) async throws -> ReminderInfo
}

// MARK: - EventKit implementation

final class EventKitRemindersService: RemindersServicing, @unchecked Sendable {
    /// Serial queue for this service.
    private let queue = AppleServiceQueue(label: "reminders")
    /// Confined to `queue`; created on first use after the access check and
    /// reset on authorization changes (see `EventKitCalendarService.store`).
    nonisolated(unsafe) private var storeBox: EKEventStore?
    nonisolated(unsafe) private var storeStatus: EKAuthorizationStatus?

    private var store: EKEventStore {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if let existing = storeBox, storeStatus == status { return existing }
        storeBox?.reset()
        let fresh = EKEventStore()
        storeBox = fresh
        storeStatus = status
        return fresh
    }

    private func requireAccess() throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw AppleToolError.permissionDenied(
                .reminders, detail: "Reminders needs Full Access for these tools.")
        }
    }

    func lists() async throws -> [ReminderListInfo] {
        try await queue.run { [self] in
            try self.requireAccess()
            let defaultId = self.store.defaultCalendarForNewReminders()?.calendarIdentifier
            return self.store.calendars(for: .reminder)
                .map {
                    ReminderListInfo(
                        id: $0.calendarIdentifier,
                        title: $0.title,
                        account: $0.source?.title ?? "",
                        color: AppleServiceSupport.hexString($0.cgColor),
                        isEditable: $0.allowsContentModifications,
                        isDefault: $0.calendarIdentifier == defaultId
                    )
                }
                .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        }
    }

    func reminders(_ query: ReminderQuery) async throws -> [ReminderInfo] {
        let all = try await fetchReminders(query)
        var items = all
        // The predicate already selects by status; keep the filter for the
        // `.all` path and as a guard against stale completion flags.
        switch query.status {
        case .incomplete: items = items.filter { !$0.isCompleted }
        case .completed: items = items.filter { $0.isCompleted }
        case .all: break
        }
        if let after = query.dueAfter { items = items.filter { ($0.dueDate ?? .distantPast) >= after } }
        if let before = query.dueBefore { items = items.filter { ($0.dueDate ?? .distantFuture) < before } }
        if let q = query.query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            items = items.filter {
                AppleServiceSupport.matches($0.title, query: q) || AppleServiceSupport.matches($0.notes, query: q)
            }
        }
        // Due soonest first; undated last; then title.
        items.sort {
            switch ($0.dueDate, $1.dueDate) {
            case let (a?, b?): return a != b ? a < b : $0.title < $1.title
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return $0.title < $1.title
            }
        }
        return items
    }

    func reminder(id: String) async throws -> ReminderInfo {
        try await queue.run { [self] in
            try self.requireAccess()
            return Self.info(try self.fetch(id: id))
        }
    }

    func create(_ draft: ReminderDraft) async throws -> ReminderInfo {
        try await queue.run { [self] in
            try self.requireAccess()
            let reminder = EKReminder(eventStore: self.store)
            if let listId = draft.listId {
                reminder.calendar = try self.resolveList(listId)
            } else if let defaultList = self.store.defaultCalendarForNewReminders(), defaultList.allowsContentModifications {
                reminder.calendar = defaultList
            } else if let first = self.store.calendars(for: .reminder).first(where: { $0.allowsContentModifications }) {
                reminder.calendar = first
            } else {
                throw AppleToolError.unavailable("No writable list is available in Reminders.")
            }
            reminder.title = draft.title
            reminder.notes = draft.notes
            reminder.url = draft.url.flatMap(URL.init(string:))
            if let due = draft.due {
                reminder.dueDateComponents = Self.components(for: due)
                reminder.startDateComponents = reminder.dueDateComponents
            }
            if let priority = draft.priority { reminder.priority = priority }
            var alarms: [EKAlarm] = []
            if let minutes = draft.alarmsMinutesBefore, let due = draft.due {
                alarms += minutes.map { AppleAlarms.absolute(minutesBefore: $0, of: due.date) }
            }
            if let at = draft.alarmAt { alarms.append(EKAlarm(absoluteDate: at)) }
            if !alarms.isEmpty { reminder.alarms = alarms }
            if let recurrence = draft.recurrence {
                guard draft.due != nil else {
                    throw AppleToolError.invalidArgs("A repeating reminder needs a `due` date.", field: "recurrence")
                }
                reminder.recurrenceRules = [try EventKitCalendarService.rule(from: recurrence)]
            }
            try self.save(reminder)
            return Self.info(reminder)
        }
    }

    func update(id: String, patch: ReminderPatch) async throws -> ReminderInfo {
        try await queue.run { [self] in
            try self.requireAccess()
            let reminder = try self.fetch(id: id)
            if let title = patch.title { reminder.title = title }
            if let listId = patch.listId { reminder.calendar = try self.resolveList(listId) }
            if let notes = patch.notes { reminder.notes = notes }
            if let url = patch.url { reminder.url = url.flatMap(URL.init(string:)) }
            // Alarms are absolute dates derived from `due`; remember their
            // offsets so a due-date change re-derives them instead of
            // leaving alerts pinned to the old time.
            let previousDue = AppleDateParsing.date(from: reminder.dueDateComponents)
            let previousOffsets: [Int] = (reminder.alarms ?? []).compactMap { alarm in
                guard let previousDue, let at = alarm.absoluteDate else { return nil }
                return Int((previousDue.timeIntervalSince(at) / 60).rounded())
            }
            var dueChanged = false
            if let due = patch.due {
                dueChanged = true
                if let due {
                    reminder.dueDateComponents = Self.components(for: due)
                    reminder.startDateComponents = reminder.dueDateComponents
                } else {
                    reminder.dueDateComponents = nil
                    reminder.startDateComponents = nil
                }
            }
            if let priority = patch.priority { reminder.priority = priority }
            let newDue = AppleDateParsing.date(from: reminder.dueDateComponents)
            if let alarms = patch.alarmsMinutesBefore {
                if let alarms, !alarms.isEmpty {
                    guard let newDue else {
                        throw AppleToolError.invalidArgs(
                            "`alarms_minutes_before` needs a `due` date to count back from (this reminder has none).",
                            field: "alarms_minutes_before")
                    }
                    reminder.alarms = alarms.map { AppleAlarms.absolute(minutesBefore: $0, of: newDue) }
                } else {
                    reminder.alarms = nil
                }
            } else if dueChanged, !previousOffsets.isEmpty {
                if let newDue {
                    reminder.alarms = previousOffsets.map { AppleAlarms.absolute(minutesBefore: $0, of: newDue) }
                } else {
                    reminder.alarms = nil
                }
            }
            if let recurrence = patch.recurrence {
                if recurrence != nil, newDue == nil {
                    throw AppleToolError.invalidArgs("A repeating reminder needs a `due` date.", field: "recurrence")
                }
                reminder.recurrenceRules = try recurrence.map { [try EventKitCalendarService.rule(from: $0)] }
            }
            if let completed = patch.isCompleted {
                reminder.isCompleted = completed
                if completed { reminder.completionDate = Date() }
            }
            try self.save(reminder)
            return Self.info(reminder)
        }
    }

    func delete(id: String) async throws -> ReminderInfo {
        try await queue.run { [self] in
            try self.requireAccess()
            let reminder = try self.fetch(id: id)
            let snapshot = Self.info(reminder)
            do {
                try self.store.remove(reminder, commit: true)
            } catch {
                throw EventKitCalendarService.eventKitError(error, verb: "Reminders delete", noun: "reminder")
            }
            return snapshot
        }
    }

    // MARK: Helpers

    /// `fetchReminders(matching:)` is callback-based. Everything that touches
    /// the store — access check, list resolution, predicate construction —
    /// runs on the service queue; the callback maps to value types before
    /// crossing back into async land. The predicate is status-based so
    /// EventKit does the completed/incomplete split instead of a full scan.
    private func fetchReminders(_ query: ReminderQuery) async throws -> [ReminderInfo] {
        try await queue.bridge { [self] complete in
            try self.requireAccess()
            let store = self.store
            let lists = try self.resolveLists(query.listIds)
            let predicate: NSPredicate
            switch query.status {
            case .incomplete:
                predicate = store.predicateForIncompleteReminders(
                    withDueDateStarting: query.dueAfter, ending: query.dueBefore, calendars: lists)
            case .completed:
                predicate = store.predicateForCompletedReminders(
                    withCompletionDateStarting: nil, ending: nil, calendars: lists)
            case .all:
                predicate = store.predicateForReminders(in: lists)
            }
            _ = store.fetchReminders(matching: predicate) { reminders in
                complete(.success((reminders ?? []).map(Self.info)))
            }
        }
    }

    private func save(_ reminder: EKReminder) throws {
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw EventKitCalendarService.eventKitError(error, verb: "Reminders save", noun: "reminder")
        }
    }

    private func fetch(id: String) throws -> EKReminder {
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw AppleToolError.notFound(
                "No reminder with id `\(id)`. Call `reminders_fetch` and pass one of its `id` values."
            )
        }
        return item
    }

    private func resolveList(_ idOrTitle: String) throws -> EKCalendar {
        let all = store.calendars(for: .reminder)
        if let byId = all.first(where: { $0.calendarIdentifier == idOrTitle }) { return byId }
        let matches = all.filter {
            $0.title.compare(idOrTitle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            let candidates = matches.map { "\($0.calendarIdentifier) (\($0.source?.title ?? "?")\($0.allowsContentModifications ? "" : ", read-only"))" }
            throw AppleToolError.invalidArgs(
                "`\(idOrTitle)` matches \(matches.count) lists; pass one of these ids instead: \(candidates.joined(separator: "; ")).",
                field: "list"
            )
        }
        throw AppleToolError.notFound(
            "No reminders list with id or title `\(idOrTitle)`. Call `reminders_lists` and pass one of its `id` values."
        )
    }

    private func resolveLists(_ ids: [String]?) throws -> [EKCalendar]? {
        guard let ids, !ids.isEmpty else { return nil }
        return try ids.map(resolveList)
    }

    static func components(for parsed: AppleParsedDate) -> DateComponents {
        let cal = Calendar.current
        if parsed.isDateOnly {
            var c = cal.dateComponents([.year, .month, .day], from: parsed.date)
            c.calendar = cal
            return c
        }
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed.date)
        c.calendar = cal
        c.timeZone = cal.timeZone
        return c
    }

    fileprivate static func info(_ reminder: EKReminder) -> ReminderInfo {
        let dueComponents = reminder.dueDateComponents
        let dueIsDateOnly = dueComponents.map { $0.hour == nil && $0.minute == nil } ?? false
        return ReminderInfo(
            id: reminder.calendarItemIdentifier,
            listId: reminder.calendar?.calendarIdentifier ?? "",
            listTitle: reminder.calendar?.title ?? "",
            title: reminder.title ?? "",
            notes: reminder.notes.flatMap { $0.isEmpty ? nil : $0 },
            url: reminder.url?.absoluteString,
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            dueDate: AppleDateParsing.date(from: dueComponents),
            dueIsDateOnly: dueIsDateOnly,
            startDate: AppleDateParsing.date(from: reminder.startDateComponents),
            priority: reminder.priority,
            priorityLabel: priorityLabel(reminder.priority),
            alarms: (reminder.alarms ?? []).map {
                CalendarAlarm(
                    minutesBefore: $0.absoluteDate == nil ? Int((-$0.relativeOffset / 60).rounded()) : nil,
                    absoluteDate: $0.absoluteDate
                )
            },
            recurrence: reminder.recurrenceRules?.first.map(EventKitCalendarService.recurrence),
            lastModified: reminder.lastModifiedDate,
            openURL: "x-apple-reminderkit://REMCDReminder/\(AppleServiceSupport.pathEncoded(reminder.calendarItemIdentifier))"
        )
    }

    static func priorityLabel(_ value: Int) -> String {
        switch value {
        case 0: return "none"
        case 1 ... 4: return "high"
        case 5: return "medium"
        default: return "low"
        }
    }

    static func priority(named name: String) -> Int? {
        switch name.lowercased() {
        case "none", "0": return 0
        case "high", "1": return 1
        case "medium", "5": return 5
        case "low", "9": return 9
        default: return Int(name).flatMap { (0 ... 9).contains($0) ? $0 : nil }
        }
    }
}
