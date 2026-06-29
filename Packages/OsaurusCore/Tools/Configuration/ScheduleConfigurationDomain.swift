//
//  ScheduleConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tool for ScheduleManager. One tool,
//  `osaurus_schedule`, fans out across four actions:
//   - create
//   - update
//   - delete
//   - enable
//
//  Schedules created from chat run without a security-scoped folder
//  context — if the user needs that, the tool tells them to use the
//  Schedules tab. `agent_id` is required for create and must be a custom
//  agent (built-ins are refused).
//

import Foundation

enum ScheduleConfigurationDomain {
    static let domain = ConfigurationDomain(
        id: "schedules",
        displayName: "Schedules",
        summary: "Scheduled agent runs — daily, weekly, cron, or one-shot.",
        menuHint: "create / update / delete / enable scheduled agent runs (daily, weekly, cron, etc.)",
        searchKeywords: [
            "schedule", "schedules", "scheduled",
            "cron", "daily", "weekly", "every morning", "every hour",
            "create schedule", "set up schedule",
            "update schedule", "edit schedule",
            "delete schedule", "remove schedule",
            "enable schedule", "disable schedule", "pause schedule",
        ],
        exampleQueries: [
            "summarize news every morning at 8",
            "create a daily schedule",
            "disable my morning news schedule",
            "delete the weekly report schedule",
        ],
        tools: [
            OsaurusScheduleTool()
        ],
        writeToolNames: [
            "osaurus_schedule"
        ]
    )
}

// MARK: - shared parsing

/// Outcome of parsing the `(frequency, value, time_of_day)` triple.
/// The failure payload is a pre-formatted `ToolEnvelope.failure` JSON
/// string, which is why we don't use `Result` — its `Failure` must
/// conform to `Error`.
enum ScheduleFrequencyParseOutcome {
    case parsed(ScheduleFrequency)
    case failureEnvelope(String)
}

enum ScheduleFrequencyParsing {
    /// Parse a flat `(frequency, value, time_of_day)` triple into a
    /// `ScheduleFrequency`. Returns a `ToolEnvelope.failure` JSON string
    /// on error so callers can `return` it directly.
    static func parse(
        toolName: String,
        frequency: String,
        value: String?,
        timeOfDay: String?
    ) -> ScheduleFrequencyParseOutcome {
        func parseTime(_ s: String?) -> (Int, Int)? {
            guard let s, let i = s.firstIndex(of: ":") else { return nil }
            let hh = String(s[..<i])
            let mm = String(s[s.index(after: i)...])
            guard let h = Int(hh), let m = Int(mm),
                (0 ..< 24).contains(h), (0 ..< 60).contains(m)
            else { return nil }
            return (h, m)
        }

        switch frequency {
        case "once":
            guard let v = value,
                let date = ISO8601DateFormatter().date(from: v)
            else {
                return .failureEnvelope(
                    ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "`frequency: 'once'` requires `frequency_value` = ISO8601 datetime.",
                        field: "frequency_value",
                        tool: toolName
                    )
                )
            }
            return .parsed(.once(date: date))
        case "every_n_minutes":
            guard let v = value, let n = Int(v), n >= 5 else {
                return .failureEnvelope(
                    ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "`frequency: 'every_n_minutes'` requires `frequency_value` >= 5.",
                        field: "frequency_value",
                        tool: toolName
                    )
                )
            }
            return .parsed(.everyNMinutes(minutes: n))
        case "hourly":
            return .parsed(.hourly(minute: 0))
        case "daily":
            guard let t = parseTime(timeOfDay) else {
                return .failureEnvelope(
                    ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "`frequency: 'daily'` requires `frequency_time_of_day` = `HH:mm`.",
                        field: "frequency_time_of_day",
                        tool: toolName
                    )
                )
            }
            return .parsed(.daily(hour: t.0, minute: t.1))
        case "weekly":
            let weekdays = ["SUN": 1, "MON": 2, "TUE": 3, "WED": 4, "THU": 5, "FRI": 6, "SAT": 7]
            // Accept full names ("Monday"), abbreviations ("MON"), and plurals
            // ("Mondays") by normalizing to the first three uppercased letters —
            // every English weekday is uniquely keyed by its 3-letter prefix. A
            // model naturally emits "Monday", so rejecting anything but "MON"
            // sends it into a retry loop it can't escape.
            let normalizedDay = value.map { String($0.uppercased().prefix(3)) }
            guard let key = normalizedDay, let day = weekdays[key],
                let t = parseTime(timeOfDay)
            else {
                return .failureEnvelope(
                    ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message:
                            "`frequency: 'weekly'` requires `frequency_value` = a weekday "
                            + "(MON..SUN or a full name like Monday) and `frequency_time_of_day` = `HH:mm`.",
                        tool: toolName
                    )
                )
            }
            return .parsed(.weekly(dayOfWeek: day, hour: t.0, minute: t.1))
        case "monthly":
            guard let v = value, let d = Int(v), (1 ... 28).contains(d),
                let t = parseTime(timeOfDay)
            else {
                return .failureEnvelope(
                    ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message:
                            "`frequency: 'monthly'` requires `frequency_value` ∈ 1..28 (day of month) "
                            + "and `frequency_time_of_day` = `HH:mm`.",
                        tool: toolName
                    )
                )
            }
            return .parsed(.monthly(dayOfMonth: d, hour: t.0, minute: t.1))
        case "yearly":
            guard let v = value, let dash = v.firstIndex(of: "-") else {
                return .failureEnvelope(
                    ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "`frequency: 'yearly'` requires `frequency_value` = `MM-DD`.",
                        tool: toolName
                    )
                )
            }
            let mm = String(v[..<dash])
            let dd = String(v[v.index(after: dash)...])
            guard let m = Int(mm), let d = Int(dd),
                (1 ... 12).contains(m), (1 ... 31).contains(d),
                let t = parseTime(timeOfDay)
            else {
                return .failureEnvelope(
                    ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message:
                            "`frequency: 'yearly'` requires `frequency_value` = `MM-DD` and "
                            + "`frequency_time_of_day` = `HH:mm`.",
                        tool: toolName
                    )
                )
            }
            return .parsed(.yearly(month: m, day: d, hour: t.0, minute: t.1))
        case "cron":
            guard let v = value, !v.isEmpty else {
                return .failureEnvelope(
                    ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "`frequency: 'cron'` requires `frequency_value` = cron expression.",
                        field: "frequency_value",
                        tool: toolName
                    )
                )
            }
            return .parsed(.cron(expression: v))
        default:
            return .failureEnvelope(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "`frequency` must be one of: once, every_n_minutes, hourly, daily, weekly, "
                        + "monthly, yearly, cron.",
                    field: "frequency",
                    tool: toolName
                )
            )
        }
    }
}

private let scheduleFrequencyValues: [String] = [
    "once", "every_n_minutes", "hourly", "daily", "weekly", "monthly", "yearly", "cron",
]

private let scheduleFrequencyDescription =
    "How often the run fires. Pair with `frequency_value` / `frequency_time_of_day`: "
    + "once=ISO8601 datetime; every_n_minutes=int>=5; hourly=none; daily=`HH:mm`; "
    + "weekly=MON..SUN + `HH:mm`; monthly=1..28 + `HH:mm`; yearly=`MM-DD` + `HH:mm`; cron=expression."

// MARK: - osaurus_schedule

public final class OsaurusScheduleTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_schedule"
    public let description =
        "Manage scheduled agent runs. `action`: create (needs `name`, `instructions`, `agent_id` of a custom "
        + "agent, `frequency`), update (needs `id`; other fields patch), delete (needs `id`), enable (needs "
        + "`id`; resumes the schedule), disable (needs `id`; pauses it). Chat-created schedules attach no "
        + "folder context — point the user to the Schedules tab if they need one."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("create"), .string("update"), .string("delete"),
                    .string("enable"), .string("disable"),
                ]),
                "description": .string("Operation to perform."),
            ]),
            "id": .object([
                "type": .string("string"),
                "description": .string("Schedule UUID. Required for update / delete / enable / disable."),
            ]),
            "name": .object(["type": .string("string")]),
            "instructions": .object(["type": .string("string")]),
            "agent_id": .object([
                "type": .string("string"),
                "description": .string("UUID of a custom agent. Required for create."),
            ]),
            "frequency": .object([
                "type": .string("string"),
                "enum": .array(scheduleFrequencyValues.map { .string($0) }),
                "description": .string(scheduleFrequencyDescription),
            ]),
            "frequency_value": .object(["type": .string("string")]),
            "frequency_time_of_day": .object(["type": .string("string")]),
            "enabled": .object(["type": .string("boolean")]),
        ]),
        "required": .array([.string("action")]),
    ])

    public var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let actionReq = requireAction(
            args,
            allowed: ["create", "update", "delete", "enable", "disable"]
        )
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "create": return await handleCreate(args)
        case "update": return await handleUpdate(args)
        case "delete": return await handleDelete(args)
        case "enable", "disable": return await handleEnable(args, action: action)
        default: return actionReq.failureEnvelope ?? ""
        }
    }

    private func handleCreate(_ args: [String: Any]) async -> String {
        // Surface ALL missing required fields in one error. Validating them one
        // at a time (name, THEN instructions, THEN agent_id, THEN frequency)
        // makes a model that sends a partial create discover the schema field
        // by field across separate tool iterations, which can exhaust its tool
        // budget and loop. Listing everything missing up front lets it resend a
        // complete call in a single retry.
        let requiredForCreate: [(key: String, hint: String)] = [
            ("name", "display name"),
            ("instructions", "what the scheduled run should do"),
            ("agent_id", "UUID of a custom agent (not the Default agent)"),
            ("frequency", "once | hourly | daily | weekly | monthly | interval | cron"),
        ]
        let missing = requiredForCreate.filter { field in
            guard let value = args[field.key] as? String else { return true }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if missing.count > 1 {
            let list = missing.map { "`\($0.key)` (\($0.hint))" }.joined(separator: ", ")
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Schedule create is missing required fields: \(list). "
                    + "Send them all together in one "
                    + "osaurus_schedule({action:'create', ...}) call.",
                field: missing.first?.key,
                tool: name
            )
        }
        let nameReq = requireString(args, "name", expected: "non-empty display name", tool: name)
        guard case .value(let scheduleName) = nameReq else { return nameReq.failureEnvelope ?? "" }
        let instrReq = requireString(args, "instructions", expected: "non-empty instructions", tool: name)
        guard case .value(let instructions) = instrReq else { return instrReq.failureEnvelope ?? "" }
        let agentReq = requireString(args, "agent_id", expected: "UUID of a custom agent", tool: name)
        guard case .value(let agentIdStr) = agentReq else { return agentReq.failureEnvelope ?? "" }
        guard let agentId = UUID(uuidString: agentIdStr) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`agent_id` must be a valid UUID.",
                field: "agent_id",
                tool: name
            )
        }
        if agentId == Agent.defaultId {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Schedules cannot target the Default agent. "
                    + "Create or pick a custom agent with osaurus_agent({action: 'create'}) / "
                    + "osaurus_list({scope:'agents'}).",
                field: "agent_id",
                tool: name,
                retryable: false
            )
        }
        let freqReq = requireString(args, "frequency", expected: "schedule frequency name", tool: name)
        guard case .value(let frequency) = freqReq else { return freqReq.failureEnvelope ?? "" }
        let value = args["frequency_value"] as? String
        let timeOfDay = args["frequency_time_of_day"] as? String

        let parsed = ScheduleFrequencyParsing.parse(
            toolName: name,
            frequency: frequency,
            value: value,
            timeOfDay: timeOfDay
        )
        let scheduleFrequency: ScheduleFrequency
        switch parsed {
        case .parsed(let f): scheduleFrequency = f
        case .failureEnvelope(let envelope): return envelope
        }

        let isEnabled = coerceBool(args["enabled"]) ?? true

        return await MainActor.run {
            guard AgentManager.shared.agent(for: agentId) != nil else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No agent found with id \(agentIdStr).",
                    field: "agent_id",
                    tool: name
                )
            }
            let schedule = ScheduleManager.shared.create(
                name: scheduleName,
                instructions: instructions,
                agentId: agentId,
                parameters: [:],
                folderPath: nil,
                folderBookmark: nil,
                frequency: scheduleFrequency,
                isEnabled: isEnabled
            )
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "schedule_id": schedule.id.uuidString,
                    "name": schedule.name,
                    "status": "created",
                    "frequency": frequency,
                ]
            )
        }
    }

    private func handleUpdate(_ args: [String: Any]) async -> String {
        let idReq = requireString(args, "id", expected: "schedule UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "`id` must be a valid UUID.", tool: name)
        }

        // If a frequency patch is provided, parse early so we surface a
        // useful error before touching MainActor state.
        var newFrequency: ScheduleFrequency? = nil
        if let freqStr = args["frequency"] as? String {
            let value = args["frequency_value"] as? String
            let timeOfDay = args["frequency_time_of_day"] as? String
            let parsed = ScheduleFrequencyParsing.parse(
                toolName: name,
                frequency: freqStr,
                value: value,
                timeOfDay: timeOfDay
            )
            switch parsed {
            case .parsed(let f): newFrequency = f
            case .failureEnvelope(let envelope): return envelope
            }
        }

        // Extract patch values into Sendable locals before the @MainActor hop;
        // capturing the raw `args` dictionary there trips the concurrency checker.
        let newName = args["name"] as? String
        let newInstructions = args["instructions"] as? String
        let newEnabled = coerceBool(args["enabled"])

        return await MainActor.run {
            guard var schedule = ScheduleManager.shared.schedule(for: id) else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No schedule found with id \(idStr).",
                    field: "id",
                    tool: name
                )
            }
            if let v = newName { schedule.name = v }
            if let v = newInstructions { schedule.instructions = v }
            if let f = newFrequency { schedule.frequency = f }
            if let b = newEnabled { schedule.isEnabled = b }

            ScheduleManager.shared.update(schedule)
            return ToolEnvelope.success(
                tool: name,
                result: ["schedule_id": schedule.id.uuidString, "status": "updated"]
            )
        }
    }

    private func handleDelete(_ args: [String: Any]) async -> String {
        let idReq = requireString(args, "id", expected: "schedule UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "`id` must be a valid UUID.", tool: name)
        }

        let deleted: Bool = await MainActor.run { ScheduleManager.shared.delete(id: id) }
        if !deleted {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No schedule found with id \(idStr).",
                field: "id",
                tool: name
            )
        }
        return ToolEnvelope.success(
            tool: name,
            result: ["schedule_id": id.uuidString, "status": "deleted"]
        )
    }

    private func handleEnable(_ args: [String: Any], action: String) async -> String {
        let idReq = requireString(args, "id", expected: "schedule UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "`id` must be a valid UUID.", tool: name)
        }
        // The action carries the intent (`enable`→resume, `disable`→pause); an
        // explicit `enabled` boolean overrides it. Lets a model say
        // `action: disable` directly instead of `enable` + `enabled:false`.
        let enabled = coerceBool(args["enabled"]) ?? (action == "enable")

        let ok: Bool = await MainActor.run {
            guard ScheduleManager.shared.schedule(for: id) != nil else { return false }
            ScheduleManager.shared.setEnabled(id, enabled: enabled)
            return true
        }
        guard ok else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No schedule found with id \(idStr).",
                field: "id",
                tool: name
            )
        }
        return ToolEnvelope.success(
            tool: name,
            result: ["schedule_id": id.uuidString, "enabled": enabled, "status": "updated"]
        )
    }
}
