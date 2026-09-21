//
//  RemindersTools.swift
//  osaurus
//
//  Built-in `reminders_*` tools (per-agent opt-in via `AppleApp.reminders`).
//

import AppKit
import Foundation

enum RemindersToolFactory {
    static func makeTools(service: RemindersServicing = EventKitRemindersService()) -> [OsaurusTool] {
        [
            RemindersListsTool(service: service),
            RemindersFetchTool(service: service),
            RemindersCreateTool(service: service),
            RemindersUpdateTool(service: service),
            RemindersCompleteTool(service: service),
            RemindersDeleteTool(service: service),
            RemindersOpenTool(service: service),
        ]
    }

    /// The schema is a closed enum of words; numeric 0–9 is accepted at
    /// runtime for models that echo EventKit's raw values back.
    static let priorityValues = ["none", "low", "medium", "high"]
    static let priorityDescription = "Priority: none, low, medium, or high."

    static func priority(_ args: [String: Any]) throws -> Int? {
        guard let raw = args["priority"], !(raw is NSNull) else { return nil }
        if let n = ArgumentCoercion.int(raw) {
            guard (0 ... 9).contains(n) else {
                throw AppleToolError.invalidArgs("`priority` must be none | low | medium | high.", field: "priority")
            }
            return n
        }
        if let s = raw as? String, let p = EventKitRemindersService.priority(named: s) { return p }
        throw AppleToolError.invalidArgs("`priority` must be none | low | medium | high.", field: "priority")
    }
}

// MARK: - reminders_lists

final class RemindersListsTool: AppleToolBase, @unchecked Sendable {
    private let service: RemindersServicing

    init(service: RemindersServicing) {
        self.service = service
        super.init(
            app: .reminders,
            name: "reminders_lists",
            description:
                "List the user's Reminders lists (id, title, account, color, editable, default). Call this before creating a reminder in a specific list.",
            parameters: AppleSchema.object([:]),
            isWrite: false
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let lists = try await service.lists()
        return AppleToolPayload(["lists": lists, "count": lists.count])
    }
}

// MARK: - reminders_fetch

final class RemindersFetchTool: AppleToolBase, @unchecked Sendable {
    private let service: RemindersServicing
    static let defaultLimit = 50

    init(service: RemindersServicing) {
        self.service = service
        super.init(
            app: .reminders,
            name: "reminders_fetch",
            description:
                "Fetch or search reminders. Defaults to incomplete reminders across all lists, due soonest first (undated last). Filter by list, status, due-date range, or text. Returns each reminder's id for reminders_update / reminders_complete / reminders_delete.",
            parameters: AppleSchema.object([
                "lists": AppleSchema.stringArray("Restrict to these list ids or titles (from reminders_lists)."),
                "status": AppleSchema.string("Which reminders to include (default incomplete).", enum: ["incomplete", "completed", "all"]),
                "due_after": AppleSchema.date("Only reminders due on/after this date."),
                "due_before": AppleSchema.date("Only reminders due before this date (a bare date is inclusive)."),
                "query": AppleSchema.string("Case-insensitive text to match in the title or notes."),
                "limit": AppleSchema.limit(default: Self.defaultLimit),
            ]),
            isWrite: false
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let statusRaw = try AppleArgs.enumeration(args, "status", allowed: ["incomplete", "completed", "all"], default: "incomplete")
        let limit = try AppleArgs.limit(args, default: Self.defaultLimit)
        let query = ReminderQuery(
            listIds: try AppleArgs.stringArray(args, "lists"),
            status: ReminderStatusFilter(rawValue: statusRaw ?? "incomplete") ?? .incomplete,
            dueAfter: try AppleArgs.date(args, "due_after")?.date,
            dueBefore: try AppleArgs.date(args, "due_before")?.exclusiveRangeEnd,
            query: try AppleArgs.string(args, "query")
        )
        let items = try await service.reminders(query)
        let page = AppleServiceSupport.page(items, limit: limit)
        return AppleToolPayload([
            "reminders": page.items,
            "count": page.items.count,
            "total": page.total,
            "truncated": page.truncated,
            "status": query.status.rawValue,
        ])
    }
}

// MARK: - reminders_create

final class RemindersCreateTool: AppleToolBase, @unchecked Sendable {
    private let service: RemindersServicing

    init(service: RemindersServicing) {
        self.service = service
        super.init(
            app: .reminders,
            name: "reminders_create",
            description:
                "Create a reminder. Requires `title`; optionally set the list, notes, URL, due date (a bare date makes an all-day reminder), priority, alerts, and a repeat rule. Returns the created reminder including its id.",
            parameters: AppleSchema.object(
                [
                    "title": AppleSchema.string("Reminder title."),
                    "list": AppleSchema.string("List id or title (from reminders_lists). Default: the user's default list."),
                    "notes": AppleSchema.string("Notes."),
                    "url": AppleSchema.string("Related URL."),
                    "due": AppleSchema.date("Due date/time."),
                    "priority": AppleSchema.string(RemindersToolFactory.priorityDescription, enum: RemindersToolFactory.priorityValues),
                    "alarms_minutes_before": AppleSchema.integerArray("Alerts in minutes before the due time (needs `due`)."),
                    "alarm_at": AppleSchema.date("An absolute alert time."),
                    "recurrence": AppleSchema.recurrence,
                ],
                required: ["title"]
            ),
            isWrite: true
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let draft = ReminderDraft(
            title: try AppleArgs.requiredString(args, "title", expected: "the reminder title"),
            listId: try AppleArgs.string(args, "list"),
            notes: try AppleArgs.string(args, "notes"),
            url: try AppleArgs.string(args, "url"),
            due: try AppleArgs.date(args, "due"),
            priority: try RemindersToolFactory.priority(args),
            alarmsMinutesBefore: try CalendarArgs.alarms(args),
            alarmAt: try AppleArgs.date(args, "alarm_at")?.date,
            recurrence: try CalendarArgs.recurrence(args)
        )
        if draft.alarmsMinutesBefore != nil, draft.due == nil {
            throw AppleToolError.invalidArgs(
                "`alarms_minutes_before` needs a `due` date to count back from.", field: "alarms_minutes_before"
            )
        }
        if draft.recurrence != nil, draft.due == nil {
            throw AppleToolError.invalidArgs("A repeating reminder needs a `due` date.", field: "recurrence")
        }
        let created = try await service.create(draft)
        return AppleToolPayload(
            ["reminder": created, "created": true],
            warnings: [CalendarArgs.alarmWarning(draft.alarmsMinutesBefore)].compactMap { $0 })
    }
}

// MARK: - reminders_update

final class RemindersUpdateTool: AppleToolBase, @unchecked Sendable {
    private let service: RemindersServicing

    init(service: RemindersServicing) {
        self.service = service
        super.init(
            app: .reminders,
            name: "reminders_update",
            description:
                "Update a reminder by `id` (from reminders_fetch). Only supplied fields change. Pass null to clear notes/url/due (changing `due` moves existing alerts by the same offset), `clear_recurrence: true` to remove the repeat rule, or `completed` to mark it done/undone.",
            parameters: AppleSchema.object(
                [
                    "id": AppleSchema.string("Reminder id from reminders_fetch."),
                    "title": AppleSchema.string("New title."),
                    "list": AppleSchema.string("Move to this list (id or title)."),
                    "notes": AppleSchema.nullableString("New notes (null clears)."),
                    "url": AppleSchema.nullableString("New URL (null clears)."),
                    "due": AppleSchema.nullableDate("New due date/time (null clears)."),
                    "priority": AppleSchema.string(RemindersToolFactory.priorityDescription, enum: RemindersToolFactory.priorityValues),
                    "alarms_minutes_before": AppleSchema.integerArray("Replace alerts with these minutes-before values ([] removes all; needs a due date)."),
                    "recurrence": AppleSchema.recurrence,
                    "clear_recurrence": AppleSchema.boolean("Remove the repeat rule."),
                    "completed": AppleSchema.boolean("Mark completed (true) or incomplete (false)."),
                ],
                required: ["id"]
            ),
            isWrite: true
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a reminder id from reminders_fetch")
        var patch = ReminderPatch()
        patch.title = try AppleArgs.string(args, "title")
        patch.listId = try AppleArgs.string(args, "list")
        if args["notes"] != nil { patch.notes = .some(try AppleArgs.string(args, "notes")) }
        if args["url"] != nil { patch.url = .some(try AppleArgs.string(args, "url")) }
        if args["due"] != nil {
            if let raw = try AppleArgs.string(args, "due") {
                guard let parsed = AppleDateParsing.parse(raw) else {
                    throw AppleToolError.invalidArgs(
                        "`due` could not be parsed as a date.", field: "due", expected: AppleDateParsing.contractDescription
                    )
                }
                patch.due = .some(parsed)
            } else {
                patch.due = .some(nil)
            }
        }
        patch.priority = try RemindersToolFactory.priority(args)
        if args["alarms_minutes_before"] != nil { patch.alarmsMinutesBefore = .some(try CalendarArgs.alarms(args) ?? []) }
        if try AppleArgs.bool(args, "clear_recurrence") == true {
            patch.recurrence = .some(nil)
        } else if let recurrence = try CalendarArgs.recurrence(args) {
            patch.recurrence = .some(recurrence)
        }
        patch.isCompleted = try AppleArgs.bool(args, "completed")
        guard !patch.isEmpty else {
            throw AppleToolError.invalidArgs("Nothing to update: pass at least one field besides `id`.")
        }
        let updated = try await service.update(id: id, patch: patch)
        return AppleToolPayload(
            ["reminder": updated, "updated": true],
            warnings: [CalendarArgs.alarmWarning(patch.alarmsMinutesBefore ?? nil)].compactMap { $0 })
    }
}

// MARK: - reminders_complete

final class RemindersCompleteTool: AppleToolBase, @unchecked Sendable {
    private let service: RemindersServicing

    init(service: RemindersServicing) {
        self.service = service
        super.init(
            app: .reminders,
            name: "reminders_complete",
            description: "Mark a reminder completed (default) or reopen it with `completed: false`.",
            parameters: AppleSchema.object(
                [
                    "id": AppleSchema.string("Reminder id from reminders_fetch."),
                    "completed": AppleSchema.boolean("true to complete (default), false to reopen."),
                ],
                required: ["id"]
            ),
            isWrite: true
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a reminder id from reminders_fetch")
        let completed = try AppleArgs.bool(args, "completed") ?? true
        var patch = ReminderPatch()
        patch.isCompleted = completed
        let updated = try await service.update(id: id, patch: patch)
        return AppleToolPayload(["reminder": updated, "completed": completed])
    }
}

// MARK: - reminders_delete

final class RemindersDeleteTool: AppleToolBase, PerCallApprovalTool, @unchecked Sendable {
    private let service: RemindersServicing

    init(service: RemindersServicing) {
        self.service = service
        super.init(
            app: .reminders,
            name: "reminders_delete",
            description: "Delete a reminder by `id`. Irreversible; the user approves every call. Prefer reminders_complete unless the user asked to delete.",
            parameters: AppleSchema.object(
                ["id": AppleSchema.string("Reminder id from reminders_fetch.")],
                required: ["id"]
            ),
            isWrite: true
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a reminder id from reminders_fetch")
        let deleted = try await service.delete(id: id)
        return AppleToolPayload(["reminder": deleted, "deleted": true])
    }
}

// MARK: - reminders_open

final class RemindersOpenTool: AppleToolBase, @unchecked Sendable {
    private let service: RemindersServicing

    init(service: RemindersServicing) {
        self.service = service
        super.init(
            app: .reminders,
            name: "reminders_open",
            description: "Open a reminder in the Reminders app by `id` so the user can see it.",
            parameters: AppleSchema.object(
                ["id": AppleSchema.string("Reminder id from reminders_fetch.")],
                required: ["id"]
            ),
            isWrite: false
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a reminder id from reminders_fetch")
        let reminder = try await service.reminder(id: id)
        guard let url = URL(string: reminder.openURL) else {
            throw AppleToolError.execution("Could not build a Reminders link for `\(id)`.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            throw AppleToolError.unavailable("Reminders could not be opened for `\(reminder.title)`.", retryable: true)
        }
        return AppleToolPayload(["opened": true, "reminder": reminder])
    }
}
