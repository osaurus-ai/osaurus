//
//  EventWebhookIngress.swift
//  osaurus
//
//  `POST /events/{token}` fires a webhook event; `GET /events/{token}/runs/{runId}`
//  reports how that fire went. Bearer-exempt like `/channels/`: the
//  unguessable URL token picks the event, and the event's own check (a
//  shared-secret header, an HMAC of the raw body, or its provider's
//  signing scheme) authenticates the caller before the body is
//  interpreted. Reachable through the agent relay as
//  `https://<agent-address>.agent.osaurus.ai/events/{token}`.
//
//  The checks themselves live in `WebhookEventSource.receive`, driven by
//  the event's `WebhookProviderProfile`; this type routes and answers.
//

import Foundation

struct EventWebhookIngressRequest: Sendable {
    var method: String
    var headers: [String: String]
    var query: [String: String]
    var body: Data
    var sourceAddress: String?
    var receivedAt: Date = Date()
    /// Path and query as received; providers that sign the URL need it.
    var uri: String? = nil
}

struct EventWebhookIngressResponse: Sendable, Equatable {
    var status: Int
    var body: String
    var contentType: String = "application/json; charset=utf-8"
}

@MainActor
final class EventWebhookIngress {
    static let shared = EventWebhookIngress()

    enum Route: Equatable, Sendable {
        case fire(token: String)
        case runStatus(token: String, runId: UUID)
    }

    /// Headers that carry a sender's delivery id, in preference order.
    nonisolated static let dedupeHeaders = WebhookProviderProfile.genericDeliveryHeaders
    nonisolated static let conversationHeader = "X-Osaurus-Conversation"

    private let manager: EventManager
    private let secretLookup: @MainActor (UUID) -> String?

    init(
        manager: EventManager = .shared,
        secretLookup: @escaping @MainActor (UUID) -> String? = { EventSecretsKeychain.secret(eventID: $0) }
    ) {
        self.manager = manager
        self.secretLookup = secretLookup
    }

    nonisolated static func route(for path: String) -> Route? {
        let trimmed = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.first == "events", parts.count >= 2, !parts[1].isEmpty else { return nil }
        if parts.count == 2 { return .fire(token: parts[1]) }
        if parts.count == 4, parts[2] == "runs", let id = UUID(uuidString: parts[3]) {
            return .runStatus(token: parts[1], runId: id)
        }
        return nil
    }

    // MARK: - Fire

    func handleFire(token: String, request: EventWebhookIngressRequest) async -> EventWebhookIngressResponse {
        await manager.awaitLoaded()
        guard let event = manager.event(forWebhookToken: token), event.source.webhook != nil else {
            return Self.error(404, "not_found", "No webhook event at this URL.")
        }
        return await manager.webhookSource.receive(
            token: token, event: event, request: request, secretLookup: secretLookup)
    }

    /// A GET on the fire URL. nil unless the event's provider answers a GET
    /// handshake (the caller then sends 405 as before).
    func handleFireGet(token: String, request: EventWebhookIngressRequest) async -> EventWebhookIngressResponse? {
        await manager.awaitLoaded()
        guard let event = manager.event(forWebhookToken: token) else { return nil }
        return await manager.webhookSource.receiveGet(event: event, request: request, secretLookup: secretLookup)
    }

    // MARK: - Run status

    func handleRunStatus(token: String, runId: UUID) async -> EventWebhookIngressResponse {
        await manager.awaitLoaded()
        guard let event = manager.event(forWebhookToken: token) else {
            return Self.error(404, "not_found", "No webhook event at this URL.")
        }
        guard let run = await manager.run(id: runId), run.eventId == event.id else {
            return Self.error(404, "run_not_found", "No such run for this automation.")
        }
        var body: [String: Any] = [
            "run_id": run.id.uuidString.lowercased(),
            "status": run.status.rawValue,
            "fired_at": Self.iso(run.firedAt),
        ]
        if let reason = run.reason { body["reason"] = reason }
        if let error = run.error { body["error"] = error }
        if let startedAt = run.startedAt { body["started_at"] = Self.iso(startedAt) }
        if let finishedAt = run.finishedAt { body["finished_at"] = Self.iso(finishedAt) }
        if let workflowRunId = run.workflowRunId { body["workflow_run_id"] = workflowRunId.uuidString.lowercased() }
        return EventWebhookIngressResponse(status: 200, body: Self.json(body))
    }

    // MARK: - Helpers

    func resetRateLimits() {
        manager.webhookSource.resetRateLimits()
    }

    nonisolated static func header(_ name: String, in headers: [String: String]) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmptyString
    }

    nonisolated static func query(fromURI uri: String) -> [String: String] {
        guard let components = URLComponents(string: uri), let items = components.queryItems else { return [:] }
        var out: [String: String] = [:]
        for item in items where out[item.name] == nil { out[item.name] = item.value ?? "" }
        return out
    }

    nonisolated static func error(_ status: Int, _ code: String, _ message: String) -> EventWebhookIngressResponse {
        EventWebhookIngressResponse(status: status, body: errorBody(code, message))
    }

    nonisolated static func errorBody(_ code: String, _ message: String) -> String {
        json(["error": ["code": code, "message": message, "type": "event_error"]])
    }

    nonisolated static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

extension String {
    fileprivate var nilIfEmptyString: String? { isEmpty ? nil : self }
}
