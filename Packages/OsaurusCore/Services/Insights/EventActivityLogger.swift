//
//  EventActivityLogger.swift
//  osaurus
//
//  One Insights row per settled event occurrence: which event, what fired
//  it, what it ran, and how it ended. Metadata only — the payload never
//  enters the activity log; the chat or workflow run it started has the
//  content, under its own privacy rules.
//

import Foundation

enum EventActivityLogger {
    static func log(_ run: EventRun, event: OsaurusEvent?) {
        InsightsService.logEgress(
            category: .event,
            source: requestSource(run.sourceKind),
            method: "FIRE",
            path: "/events/\(run.sourceKind.rawValue)/\(slug(run.eventName))",
            statusCode: statusCode(run.status),
            durationMs: (run.durationSeconds ?? 0) * 1000,
            egress: EgressInfo(details: details(run)),
            locality: .local,
            errorMessage: run.error,
            attribution: InsightsService.ActivityAttribution(
                agentId: event?.agentId,
                sessionId: run.sessionId,
                workflowRunId: run.workflowRunId,
                taskId: run.id
            )
        )
    }

    static func details(_ run: EventRun) -> [String: String] {
        var details = run.summary
        details["event"] = run.eventName
        details["event_id"] = run.eventId.uuidString
        details["run_id"] = run.id.uuidString
        details["source"] = run.sourceKind.rawValue
        details["action"] = run.actionKind.rawValue
        details["status"] = run.status.rawValue
        if let reason = run.reason { details["reason"] = reason }
        return details
    }

    static func requestSource(_ kind: EventSourceKind) -> RequestSource {
        kind.descriptor.requestSource
    }

    static func statusCode(_ status: EventRunStatus) -> Int {
        switch status {
        case .received, .queued, .running, .awaitingUser, .succeeded: 200
        case .filtered, .duplicate, .suppressed: 204
        case .cancelled: 499
        case .failed: 500
        }
    }

    private static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let parts = name.lowercased().unicodeScalars.split { !allowed.contains($0) }
        let joined = parts.map { String(String.UnicodeScalarView($0)) }.joined(separator: "-")
        return joined.isEmpty ? "event" : joined
    }
}
