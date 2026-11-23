//
//  WebhookEventSource.swift
//  osaurus
//
//  The webhook source adapter. `EventWebhookIngress` routes
//  `POST /events/{token}` here; the event's `WebhookProviderProfile` drives
//  the checks: enabled → size → setup handshake → signature → rate limit
//  → (fetch on notify) → submit. Every refusal for a known event is
//  written to the ledger so the Automations screen can say why a delivery
//  did not run. Provider registration (install/uninstall) persists the
//  provider's webhook id in `event_source_state`.
//

import Foundation

@MainActor
final class WebhookEventSource: EventSourceAdapter {
    let kind: EventSourceKind = .webhook
    private unowned let manager: EventManager
    /// Accepted-request timestamps per event, for the per-minute limit.
    private var recentHits: [UUID: [Date]] = [:]

    init(manager: EventManager) {
        self.manager = manager
    }

    func stop() {}

    func reconcile(_ events: [OsaurusEvent]) async {
        let ids = Set(events.map(\.id))
        recentHits = recentHits.filter { ids.contains($0.key) }
    }

    func forget(_ eventId: UUID) {
        recentHits.removeValue(forKey: eventId)
    }

    func status(_ eventId: UUID) -> EventSourceStatus {
        manager.sourceStatus[eventId] ?? EventSourceStatus()
    }

    // MARK: - Registration

    static func registrationScope(_ id: UUID) -> String {
        EventRunDatabase.eventScopePrefix(id) + ":webhook"
    }

    func install(_ event: OsaurusEvent) async throws {
        guard let config = event.source.webhook,
            let registration = WebhookProviderProfile.profile(for: config).registration
        else { return }
        guard let url = Self.relayURL(for: event, token: config.token).flatMap(URL.init(string:)) else {
            throw WebhookRegistrationError.noPublicURL
        }
        let state = try await registration.install(event: event, callbackURL: url)
        manager.setSourceState(state, scope: Self.registrationScope(event.id))
        manager.setSourceStatus(event.id) { $0.installed = true }
    }

    func uninstall(_ event: OsaurusEvent) async {
        guard let config = event.source.webhook,
            let registration = WebhookProviderProfile.profile(for: config).registration
        else { return }
        let scope = Self.registrationScope(event.id)
        if let state = await manager.sourceState(scope: scope) {
            await registration.uninstall(event: event, state: state)
        }
        manager.setSourceState(nil, scope: scope)
        manager.setSourceStatus(event.id) { $0.installed = nil }
    }

    func reconcileInstalled(_ events: [OsaurusEvent]) async {
        for event in events where event.isEnabled {
            guard let config = event.source.webhook,
                let registration = WebhookProviderProfile.profile(for: config).registration
            else { continue }
            let state = await manager.sourceState(scope: Self.registrationScope(event.id))
            if let state, await registration.verify(event: event, state: state) {
                manager.setSourceStatus(event.id) { $0.installed = true }
                continue
            }
            do {
                try await install(event)
            } catch {
                manager.setSourceStatus(event.id) {
                    $0.installed = false
                    $0.lastError = error.localizedDescription
                }
            }
        }
    }

    /// The relay URL through the event's own agent when its tunnel is up,
    /// otherwise through any connected agent (the route is not
    /// agent-scoped); nil when no tunnel is up.
    static func relayURL(for event: OsaurusEvent, token: String) -> String? {
        let connected: [UUID] = RelayTunnelManager.shared.agentStatuses.compactMap { id, status in
            if case .connected = status { return id }
            return nil
        }
        let preferred =
            event.agentId.flatMap { connected.contains($0) ? $0 : nil }
            ?? connected.sorted { $0.uuidString < $1.uuidString }.first
        guard let id = preferred, let address = AgentManager.shared.agent(for: id)?.agentAddress else { return nil }
        return RelayTunnelManager.publicURL(forAddress: address) + "/events/\(token)"
    }

    // MARK: - Run Now

    /// Sends the webhook's sample body (or `sample`) as a manual fire, so a
    /// workflow bound to body fields gets real-looking input.
    func fireNow(_ event: OsaurusEvent, sample: JSONValue?) async -> EventFireResult {
        let now = Date()
        let body: Data =
            if let sample {
                Data(sample.compactJSONString.utf8)
            } else if let text = event.source.webhook?.sampleBody?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            {
                Data(text.utf8)
            } else {
                Data("{}".utf8)
            }
        return manager.submit(
            EventOccurrence(
                eventId: event.id, firedAt: now,
                payload: EventPayload.webhook(
                    event: event, firedAt: now, method: "POST", headers: [:], query: [:], body: body,
                    contentType: "application/json"),
                trigger: .manual, loadIntent: .interactive, summary: ["body_bytes": String(body.count)]))
    }

    // MARK: - Receive

    func receive(
        token: String,
        event: OsaurusEvent,
        request: EventWebhookIngressRequest,
        secretLookup: @MainActor (UUID) -> String?
    ) async -> EventWebhookIngressResponse {
        guard let webhook = event.source.webhook else {
            return EventWebhookIngress.error(404, "not_found", "No webhook event at this URL.")
        }
        let profile = WebhookProviderProfile.profile(for: webhook)
        let context = WebhookRequestContext(
            method: request.method, headers: request.headers, query: request.query, body: request.body,
            uri: request.uri, receivedAt: request.receivedAt, bodyContentType: profile.bodyContentType)
        var summary: [String: String] = ["body_bytes": String(request.body.count)]
        if let address = request.sourceAddress { summary["source_address"] = address }

        guard event.isEnabled else {
            reject(event, reason: "disabled", summary: summary)
            return EventWebhookIngress.error(409, "event_disabled", "This automation is turned off.")
        }
        guard request.body.count <= webhook.maxBodyBytes else {
            reject(event, reason: "body_too_large", summary: summary)
            return EventWebhookIngress.error(413, "body_too_large", "Body exceeds \(webhook.maxBodyBytes) bytes.")
        }
        if !profile.handshakes.isEmpty,
            let response = await WebhookHandshakeResponder.respond(
                profile.handshakes, request: context, secret: secretLookup(event.id))
        {
            return response
        }
        if profile.verifier.checksSecret {
            let secret = secretLookup(event.id)
            guard
                WebhookVerification.verify(
                    profile.verifier, request: context, secret: secret, sourceAddress: request.sourceAddress)
            else {
                reject(event, reason: secret == nil ? "secret_unavailable" : "unauthorized", summary: summary)
                return EventWebhookIngress.error(401, "unauthorized", "Signature or secret did not verify.")
            }
        }
        guard admitRate(event.id, limit: webhook.rateLimitPerMinute, now: request.receivedAt) else {
            reject(event, reason: "rate_limited", summary: summary)
            return EventWebhookIngress.error(
                429, "rate_limited", "More than \(webhook.rateLimitPerMinute) calls a minute.")
        }

        var body = request.body
        var contentType = context.contentType
        if let fetcher = profile.fetcher {
            do {
                let fetched = try await fetcher.fetch(event: event, notification: context.parsedBody)
                body = Data(fetched.compactJSONString.utf8)
                contentType = "application/json"
            } catch {
                reject(event, reason: "fetch_failed", summary: summary)
                return EventWebhookIngress.error(502, "fetch_failed", "Could not fetch the notified content.")
            }
        }

        let deliveryId = profile.deliveryId(in: context)
        let eventType = profile.eventType(in: context)
        let payload = EventPayload.webhook(
            event: event, firedAt: request.receivedAt, method: request.method, headers: request.headers,
            query: request.query, body: body, contentType: contentType, eventType: eventType)
        if let deliveryId { summary["delivery_id"] = String(deliveryId.prefix(120)) }
        if let eventType { summary["event_type"] = String(eventType.prefix(120)) }
        let result = manager.submit(
            EventOccurrence(
                eventId: event.id, firedAt: request.receivedAt, payload: payload, trigger: .source,
                dedupeKey: deliveryId.map { "webhook:\($0)" },
                conversationKey: context.header(EventWebhookIngress.conversationHeader),
                isExternal: true, loadIntent: .background, summary: summary))

        let status: Int
        switch result.status {
        case .filtered, .duplicate: status = 200
        case .suppressed: status = result.reason == "queue_full" || result.reason == "busy" ? 429 : 503
        default: status = 202
        }
        var responseBody: [String: Any] = [
            "run_id": result.runId.uuidString.lowercased(),
            "status": result.status.rawValue,
            "status_url": "/events/\(token)/runs/\(result.runId.uuidString.lowercased())",
        ]
        if let reason = result.reason { responseBody["reason"] = reason }
        return EventWebhookIngressResponse(status: status, body: EventWebhookIngress.json(responseBody))
    }

    /// A GET on the fire URL: only a provider's GET handshake answers it.
    func receiveGet(
        event: OsaurusEvent, request: EventWebhookIngressRequest, secretLookup: @MainActor (UUID) -> String?
    ) async -> EventWebhookIngressResponse? {
        guard event.isEnabled, let webhook = event.source.webhook else { return nil }
        let profile = WebhookProviderProfile.profile(for: webhook)
        guard profile.handshakes.contains(.facebookHubChallenge) else { return nil }
        let context = WebhookRequestContext(
            method: "GET", headers: request.headers, query: request.query, body: Data(), uri: request.uri,
            receivedAt: request.receivedAt)
        return await WebhookHandshakeResponder.respond(
            profile.handshakes, request: context, secret: secretLookup(event.id))
    }

    private func reject(_ event: OsaurusEvent, reason: String, summary: [String: String]) {
        let now = Date()
        manager.record(
            EventRun(
                eventId: event.id, eventName: event.name, sourceKind: .webhook, actionKind: event.action.kind,
                firedAt: now, status: .suppressed, reason: reason, finishedAt: now, summary: summary))
    }

    private func admitRate(_ eventId: UUID, limit: Int, now: Date) -> Bool {
        let windowStart = now.addingTimeInterval(-60)
        var hits = (recentHits[eventId] ?? []).filter { $0 > windowStart }
        guard hits.count < limit else {
            recentHits[eventId] = hits
            return false
        }
        hits.append(now)
        recentHits[eventId] = hits
        return true
    }

    func resetRateLimits() {
        recentHits.removeAll()
    }
}

enum WebhookRegistrationError: LocalizedError {
    case noPublicURL

    var errorDescription: String? {
        switch self {
        case .noPublicURL:
            L("This Mac has no agent address to receive webhooks on. Turn on the agent relay, then try again.")
        }
    }
}
