//
//  SchedulerTools.swift
//  osaurus
//
//  Self-scheduling + notification tools (spec §9, §10, Phase 3). Unlike
//  the `db_*` tools, these are always available to every agent — the
//  scheduler is the primary self-controlled affordance and doesn't
//  depend on the agent having opted into the database feature.
//
//  All three delegate to `LocalAgentBridge.shared`; the bridge applies
//  the clamp ladder, writes through to `SchedulerDatabase`, and surfaces
//  notifications via `NotificationService.postAgentEvent`.
//

import Foundation

// MARK: - ISO-8601 helpers
//
// ISO8601DateFormatter is not `Sendable`, so we can't cache one as a
// static. Allocating per call is cheap (<1µs on Apple Silicon) and
// keeps the tool layer free of concurrency annotations.

@inline(__always)
private func parseISO8601(_ raw: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = f.date(from: raw) { return date }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: raw)
}

@inline(__always)
private func formatISO8601(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

/// Resolve the agent's schedule bounds on MainActor (where AgentManager
/// is isolated). Falls back to ambient defaults if the agent has been
/// deleted between the tool dispatch and the call.
@MainActor
func resolveAgentScheduleBounds(_ agentId: UUID) -> AgentScheduleSettings {
    AgentManager.shared.agent(for: agentId)?.settings.schedule
        ?? AgentScheduleSettings.defaults(for: .ambient)
}

/// Resolve the agent's display name on MainActor.
@MainActor
func resolveAgentDisplayName(_ agentId: UUID) -> String {
    AgentManager.shared.agent(for: agentId)?.displayName
        ?? "Agent \(agentId.uuidString.prefix(8))"
}

// MARK: - schedule_next_run

/// Schedules the agent's next self-wake (spec §9). The bridge resolves
/// the agent's `AgentScheduleSettings` and applies the clamp ladder
/// before persisting; this tool reports the clamps back so the model
/// can reason about its own budget on the next turn.
final class ScheduleNextRunTool: OsaurusTool, @unchecked Sendable {
    let name = "schedule_next_run"
    let description =
        "Ask the host to wake you again at a future time, with a short "
        + "instruction describing what to do then. The wake runs in a "
        + "FRESH chat with no prior conversation context, so make "
        + "`instructions` self-contained (persist any state you'll need "
        + "in your agent database first). The host clamps your "
        + "request against the agent's schedule bounds (min interval, "
        + "max horizon, quiet hours, daily cap); the result tells you "
        + "the actual scheduled time and whether any clamp applied. "
        + "Calling this overwrites any previous next-run slot — there's "
        + "only one per agent."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "scheduled_at": .object([
                "type": .string("string"),
                "description": .string(
                    "ISO-8601 timestamp for the next wake. Past times are "
                        + "clamped forward to `now`."
                ),
            ]),
            "in_seconds": .object([
                "type": .string("integer"),
                "description": .string(
                    "Alternative to `scheduled_at`: wake this many seconds "
                        + "from now. Ignored when `scheduled_at` is set."
                ),
                "minimum": .number(0),
            ]),
            "instructions": .object([
                "type": .string("string"),
                "description": .string(
                    "What you'll do when you wake up. Surfaced to the user "
                        + "in the Next Run panel so they can edit it."
                ),
            ]),
            "context_views": .object([
                "type": .string("array"),
                "description": .string(
                    "Saved view names the host should prefetch before "
                        + "your next inference loop starts."
                ),
                "items": .object(["type": .string("string")]),
            ]),
            "priority": .object([
                "type": .string("string"),
                "description": .string(
                    "`normal` (default) or `low`. The scheduler may shed "
                        + "`low` priority runs when concurrency is saturated."
                ),
                "enum": .array([.string("normal"), .string("low")]),
            ]),
            "on_miss": .object([
                "type": .string("string"),
                "description": .string(
                    "What to do if the scheduler is offline when the wake "
                        + "time passes: `skip`, `run_once`, or `run_catchup`."
                ),
                "enum": .array([
                    .string("skip"), .string("run_once"), .string("run_catchup"),
                ]),
            ]),
        ]),
        "required": .array([.string("instructions")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let instructionsReq = requireString(
            args,
            "instructions",
            expected: "what to do when you wake up",
            tool: name
        )
        guard case .value(let instructions) = instructionsReq else {
            return instructionsReq.failureEnvelope ?? ""
        }

        let scheduledAt = resolveScheduledAt(args: args)
        guard let scheduledAt else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Provide either `scheduled_at` (ISO-8601) or "
                    + "`in_seconds` (non-negative integer).",
                tool: name
            )
        }

        let priority = (args["priority"] as? String).flatMap(NextRunPriority.init(rawValue:)) ?? .normal
        let onMiss = (args["on_miss"] as? String).flatMap(NextRunOnMiss.init(rawValue:)) ?? .skip
        let views: [String]
        if let raw = args["context_views"] as? [Any] {
            views = raw.compactMap { $0 as? String }
        } else {
            views = []
        }

        let request = AgentScheduleRequest(
            scheduledAt: scheduledAt,
            instructions: instructions,
            contextViews: views,
            priority: priority,
            onMiss: onMiss,
            scheduledBy: .agent
        )

        let bounds = await MainActor.run { resolveAgentScheduleBounds(agentId) }

        do {
            let result = try LocalAgentBridge.shared.scheduleNextRun(
                agentId: agentId,
                request: request,
                bounds: bounds
            )
            return Self.envelope(name: name, result: result)
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }

    /// Resolve the effective wake time from the `scheduled_at` /
    /// `in_seconds` argument pair. `scheduled_at` wins when both are
    /// supplied so the more explicit form is always honored.
    private func resolveScheduledAt(args: [String: Any]) -> Date? {
        if let raw = args["scheduled_at"] as? String, !raw.isEmpty {
            // ISO-8601 with fractional seconds OR plain — try both. We
            // don't surface a parse error here because the failure path
            // above handles "neither was supplied"; a malformed string
            // counts as "neither" and produces a single clear error.
            return parseISO8601(raw)
        }
        if let n = args["in_seconds"] as? Int {
            return Date().addingTimeInterval(TimeInterval(max(0, n)))
        }
        if let n = args["in_seconds"] as? Double {
            return Date().addingTimeInterval(max(0, n))
        }
        if let s = args["in_seconds"] as? String, let n = Int(s) {
            return Date().addingTimeInterval(TimeInterval(max(0, n)))
        }
        return nil
    }

    static func envelope(name: String, result: AgentScheduleResult) -> String {
        var payload: [String: Any] = [
            "clamped": result.clamped,
            "clamp_reasons": result.clampReasons.map { $0.rawValue },
            "remaining_budget_today": result.remainingBudgetToday,
        ]
        if let entry = result.entry {
            payload["scheduled_at"] = formatISO8601(entry.scheduledAt)
            payload["instructions"] = entry.instructions
            payload["priority"] = entry.priority.rawValue
            payload["on_miss"] = entry.onMiss.rawValue
            payload["scheduled_by"] = entry.scheduledBy.rawValue
            payload["context_views"] = entry.contextViews
        } else {
            payload["rejected"] = true
        }
        let warnings = result.clampReasons.map { Self.clampWarning($0) }
        return ToolEnvelope.success(
            tool: name,
            result: payload,
            warnings: warnings.isEmpty ? nil : warnings
        )
    }

    private static func clampWarning(_ reason: AgentScheduleClampReason) -> String {
        switch reason {
        case .minInterval:
            return "Scheduled time moved later to honor min_interval."
        case .maxHorizon:
            return "Scheduled time pulled back to max_horizon."
        case .quietHours:
            return "Scheduled time moved past quiet hours."
        case .dailyCap:
            return "Rejected: daily_run_cap exhausted in the rolling 24h window."
        case .dayNotAllowed:
            return "Scheduled time moved to the next allowed day."
        case .modeManual:
            return "Rejected: schedule mode is `manual`. Ask the user to change the mode."
        case .paused:
            return "Rejected: agent is paused. Resume from the Next Run panel to wake."
        }
    }
}

// MARK: - cancel_next_run

final class CancelNextRunTool: OsaurusTool, @unchecked Sendable {
    let name = "cancel_next_run"
    let description =
        "Clear your scheduled next-run slot. No-op when no slot exists. "
        + "Useful when you've decided the upcoming wake is no longer "
        + "needed (e.g. the user resolved the thing you were going to "
        + "check on)."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }
        do {
            let removed = try LocalAgentBridge.shared.cancelNextRun(agentId: agentId)
            return ToolEnvelope.success(tool: name, result: ["cancelled": removed])
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}

// MARK: - notify

/// Posts a notification on behalf of the agent (spec §10). Title/body
/// are agent-supplied free text; the host prefixes the title with the
/// agent's name so the user always knows who's notifying.
final class NotifyTool: OsaurusTool, @unchecked Sendable {
    let name = "notify"
    let description =
        "Surface a notification to the user. Use sparingly — only when "
        + "you have something time-sensitive to share. `view_ref` may "
        + "name a saved view; tapping the notification opens that view "
        + "in your detail panel."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "title": .object([
                "type": .string("string"),
                "description": .string("Notification title. Short — fits on a single line."),
            ]),
            "body": .object([
                "type": .string("string"),
                "description": .string("Notification body. One or two sentences."),
            ]),
            "view_ref": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional saved view name to deep-link the user to on tap."
                ),
            ]),
        ]),
        "required": .array([.string("title"), .string("body")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let agentReq = DatabaseToolHelpers.requireAgentId(tool: name)
        guard case .value(let agentId) = agentReq else { return agentReq.failureEnvelope ?? "" }

        let titleReq = requireString(args, "title", expected: "notification title", tool: name)
        guard case .value(let title) = titleReq else { return titleReq.failureEnvelope ?? "" }
        let bodyReq = requireString(args, "body", expected: "notification body", tool: name)
        guard case .value(let body) = bodyReq else { return bodyReq.failureEnvelope ?? "" }
        let viewRefReq = optionalString(args, "view_ref", expected: "saved view name")
        guard case .value(let viewRef) = viewRefReq else { return viewRefReq.failureEnvelope ?? "" }

        let agentName = await MainActor.run { resolveAgentDisplayName(agentId) }

        do {
            try LocalAgentBridge.shared.notify(
                agentId: agentId,
                agentName: agentName,
                title: title,
                body: body,
                viewRef: viewRef
            )
            return ToolEnvelope.success(tool: name, result: ["posted": true])
        } catch {
            return DatabaseToolHelpers.envelope(for: error, tool: name)
        }
    }
}
