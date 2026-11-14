//
//  EventRun.swift
//  osaurus
//
//  One fire of an event, as recorded in the event ledger
//  (`~/.osaurus/events/runs.sqlite`). Every occurrence gets a row — runs,
//  and also the ones that were filtered, de-duplicated, suppressed or
//  rejected — so "why didn't my event fire?" always has an answer.
//

import Foundation

public enum EventRunStatus: String, Codable, CaseIterable, Sendable {
    /// Accepted, not yet decided.
    case received
    /// The event's filter did not match.
    case filtered
    /// The same delivery id fired inside the dedupe window.
    case duplicate
    /// Waiting for a free lane.
    case queued
    case running
    /// A workflow run stopped for a form nobody has answered yet.
    case awaitingUser = "awaiting_user"
    case succeeded
    case failed
    case cancelled
    /// Not run: the event was busy with a full queue, its target was
    /// unavailable, a safety gate refused it, or it was rejected at the door.
    case suppressed

    public var isTerminal: Bool {
        switch self {
        case .received, .queued, .running, .awaitingUser: false
        case .filtered, .duplicate, .succeeded, .failed, .cancelled, .suppressed: true
        }
    }

    /// Whether the occurrence actually started an action.
    public var didRun: Bool {
        switch self {
        case .running, .awaitingUser, .succeeded, .failed, .cancelled: true
        case .received, .filtered, .duplicate, .queued, .suppressed: false
        }
    }

    public var displayName: String {
        switch self {
        case .received: L("Received")
        case .filtered: L("Filtered")
        case .duplicate: L("Duplicate")
        case .queued: L("Queued")
        case .running: L("Running")
        case .awaitingUser: L("Waiting for you")
        case .succeeded: L("Succeeded")
        case .failed: L("Failed")
        case .cancelled: L("Cancelled")
        case .suppressed: L("Skipped")
        }
    }
}

public struct EventRun: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var eventId: UUID
    public var eventName: String
    public var sourceKind: EventSourceKind
    public var actionKind: EventActionKind
    public var firedAt: Date
    public var status: EventRunStatus
    /// Machine reason for a non-run status (`filtered:keywords`,
    /// `queue_full`, `agent_unavailable`, …) or the matched channel rule.
    public var reason: String?
    public var dedupeKey: String?
    public var conversationKey: String?
    public var sessionId: UUID?
    public var workflowRunId: UUID?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var error: String?
    /// Metadata only (sizes, ids, counts) — never message bodies.
    public var summary: [String: String]

    public init(
        id: UUID = UUID(),
        eventId: UUID,
        eventName: String,
        sourceKind: EventSourceKind,
        actionKind: EventActionKind,
        firedAt: Date = Date(),
        status: EventRunStatus = .received,
        reason: String? = nil,
        dedupeKey: String? = nil,
        conversationKey: String? = nil,
        sessionId: UUID? = nil,
        workflowRunId: UUID? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        error: String? = nil,
        summary: [String: String] = [:]
    ) {
        self.id = id
        self.eventId = eventId
        self.eventName = eventName
        self.sourceKind = sourceKind
        self.actionKind = actionKind
        self.firedAt = firedAt
        self.status = status
        self.reason = reason
        self.dedupeKey = dedupeKey
        self.conversationKey = conversationKey
        self.sessionId = sessionId
        self.workflowRunId = workflowRunId
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
        self.summary = summary
    }

    public var durationSeconds: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }
}
