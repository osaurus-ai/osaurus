//
//  EventWebhookIngressTests.swift
//  osaurusTests
//
//  `POST /events/{token}` and `GET /events/{token}/runs/{runId}` against an
//  in-memory ledger and a fake action runner: auth, caps, the rate limit,
//  dedupe, queue refusal, and that every refusal is ledgered.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct EventWebhookIngressTests {
    static let secret = "whsec_test_secret"

    @MainActor
    final class Harness {
        let manager: EventManager
        let ingress: EventWebhookIngress
        var event: OsaurusEvent
        var fired: [EventOccurrence] = []
        var gate: [CheckedContinuation<Void, Never>] = []
        var holdRuns = false

        init(
            webhook: WebhookSourceConfig,
            filter: EventFilter = EventFilter(),
            delivery: EventDeliveryPolicy? = nil,
            isEnabled: Bool = true,
            secret: String? = EventWebhookIngressTests.secret
        ) throws {
            let ledger = EventRunDatabase()
            try ledger.openInMemory()
            manager = EventManager(ledger: ledger, persistsToDisk: false)
            manager.targetLookup = EventTargetLookup(agentExists: { _ in true })
            ingress = EventWebhookIngress(manager: manager, secretLookup: { _ in secret })
            event = manager.create(
                OsaurusEvent(
                    name: "Deploy hook",
                    isEnabled: isEnabled,
                    source: .webhook(webhook),
                    filter: filter,
                    action: .agent(AgentEventAction(target: .local(UUID()), instructions: "Summarize")),
                    delivery: delivery
                ))
            manager.runAction = { [weak self] _, _, occurrence, _ in
                guard let self else { return TaskOutcome(status: .cancelled) }
                self.fired.append(occurrence)
                if self.holdRuns {
                    await withCheckedContinuation { self.gate.append($0) }
                }
                return TaskOutcome(status: .succeeded)
            }
        }

        var token: String { event.source.webhook!.token }

        func release() {
            holdRuns = false
            for waiter in gate { waiter.resume() }
            gate.removeAll()
        }

        func fire(
            _ body: String = #"{"action":"opened","number":7}"#,
            headers: [String: String] = [:],
            signed: Bool = false
        ) async -> EventWebhookIngressResponse {
            let data = Data(body.utf8)
            var all = ["Content-Type": "application/json"].merging(headers) { _, new in new }
            if signed {
                all[WebhookSourceConfig.defaultSignatureHeader] =
                    "sha256=" + AgentChannelAsyncSubstrate.hmacSHA256Hex(body: data, secret: EventWebhookIngressTests.secret)
            }
            return await ingress.handleFire(
                token: token,
                request: EventWebhookIngressRequest(
                    method: "POST", headers: all, query: ["ref": "main"], body: data, sourceAddress: "203.0.113.9"))
        }

        func settled(_ runId: UUID) async -> EventRun? {
            for _ in 0 ..< 300 {
                if let run = await manager.run(id: runId), run.status.isTerminal { return run }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return await manager.run(id: runId)
        }

        func ledgerRows() async -> [EventRun] {
            await manager.runs(eventId: event.id)
        }
    }

    static func json(_ response: EventWebhookIngressResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(response.body.utf8))) as? [String: Any] ?? [:]
    }

    static func runId(_ response: EventWebhookIngressResponse) -> UUID? {
        (json(response)["run_id"] as? String).flatMap(UUID.init(uuidString:))
    }

    static func errorCode(_ response: EventWebhookIngressResponse) -> String? {
        (json(response)["error"] as? [String: Any])?["code"] as? String
    }

    // MARK: - Routing

    @Test func routeParsesFireAndRunStatusPaths() {
        let runId = UUID()
        #expect(EventWebhookIngress.route(for: "/events/abc") == .fire(token: "abc"))
        #expect(EventWebhookIngress.route(for: "/events/abc?x=1") == .fire(token: "abc"))
        #expect(
            EventWebhookIngress.route(for: "/events/abc/runs/\(runId.uuidString.lowercased())")
                == .runStatus(token: "abc", runId: runId))
        #expect(EventWebhookIngress.route(for: "/events/") == nil)
        #expect(EventWebhookIngress.route(for: "/events/abc/runs/not-a-uuid") == nil)
        #expect(EventWebhookIngress.route(for: "/events/abc/extra") == nil)
        #expect(EventWebhookIngress.route(for: "/channels/abc") == nil)
    }

    @Test func queryParsingKeepsFirstValue() {
        #expect(EventWebhookIngress.query(fromURI: "/events/t?a=1&b=two&a=3") == ["a": "1", "b": "two"])
        #expect(EventWebhookIngress.query(fromURI: "/events/t").isEmpty)
    }

    // MARK: - Fire

    @Test func signedFireIsAcceptedAndRunsWithParsedPayload() async throws {
        let harness = try Harness(webhook: WebhookSourceConfig(verification: .hmacSHA256))
        let response = await harness.fire(signed: true)
        #expect(response.status == 202)
        let body = Self.json(response)
        let runId = try #require(Self.runId(response))
        #expect(body["status_url"] as? String == "/events/\(harness.token)/runs/\(runId.uuidString.lowercased())")

        let run = try #require(await harness.settled(runId))
        #expect(run.status == .succeeded)
        #expect(run.summary["source_address"] == "203.0.113.9")
        let occurrence = try #require(harness.fired.first)
        #expect(occurrence.isExternal)
        #expect(occurrence.payload.value(atPath: "webhook.body.action") == .string("opened"))
        #expect(occurrence.payload.value(atPath: "webhook.query.ref") == .string("main"))
        let headers = occurrence.payload.value(atPath: "webhook.headers")?.objectValue ?? [:]
        #expect(headers.keys.allSatisfy { !$0.contains("signature") })
    }

    @Test func badSignatureIsRefusedAndLedgered() async throws {
        let harness = try Harness(webhook: WebhookSourceConfig(verification: .hmacSHA256))
        let response = await harness.fire(headers: [WebhookSourceConfig.defaultSignatureHeader: "sha256=deadbeef"])
        #expect(response.status == 401)
        #expect(Self.errorCode(response) == "unauthorized")
        #expect(harness.fired.isEmpty)
        let rows = await harness.ledgerRows()
        #expect(rows.map(\.reason) == ["unauthorized"])
        #expect(rows.first?.status == .suppressed)
    }

    @Test func missingSecretFailsClosed() async throws {
        let harness = try Harness(webhook: WebhookSourceConfig(verification: .hmacSHA256), secret: nil)
        let response = await harness.fire(signed: true)
        #expect(response.status == 401)
        #expect(await harness.ledgerRows().map(\.reason) == ["secret_unavailable"])
    }

    @Test func sharedSecretHeaderMustMatch() async throws {
        let harness = try Harness(webhook: WebhookSourceConfig(verification: .sharedSecretHeader))
        let wrong = await harness.fire(headers: [WebhookSourceConfig.defaultSecretHeader: "nope"])
        #expect(wrong.status == 401)
        let right = await harness.fire(headers: [WebhookSourceConfig.defaultSecretHeader: Self.secret])
        #expect(right.status == 202)
    }

    @Test func unsignedEventAcceptsWithoutHeaders() async throws {
        let harness = try Harness(webhook: WebhookSourceConfig(verification: .none))
        #expect(await harness.fire().status == 202)
    }

    @Test func unknownTokenIs404AndNotLedgered() async throws {
        let harness = try Harness(webhook: WebhookSourceConfig(verification: .none))
        let response = await harness.ingress.handleFire(
            token: "not-a-token",
            request: EventWebhookIngressRequest(method: "POST", headers: [:], query: [:], body: Data()))
        #expect(response.status == 404)
        #expect(await harness.ledgerRows().isEmpty)
    }

    @Test func disabledEventIs409() async throws {
        let harness = try Harness(webhook: WebhookSourceConfig(verification: .none), isEnabled: false)
        let response = await harness.fire()
        #expect(response.status == 409)
        #expect(await harness.ledgerRows().map(\.reason) == ["disabled"])
    }

    @Test func oversizedBodyIs413BeforeVerification() async throws {
        let harness = try Harness(webhook: WebhookSourceConfig(verification: .hmacSHA256, maxBodyBytes: 8))
        let response = await harness.fire(String(repeating: "x", count: 64), signed: true)
        #expect(response.status == 413)
        let rows = await harness.ledgerRows()
        #expect(rows.map(\.reason) == ["body_too_large"])
        #expect(rows.first?.summary["body_bytes"] == "64")
    }

    @Test func rateLimitRefusesPastThePerMinuteCap() async throws {
        let harness = try Harness(
            webhook: WebhookSourceConfig(verification: .none, rateLimitPerMinute: 2),
            delivery: EventDeliveryPolicy(mode: .parallel, maxConcurrent: 4, dedupeWindowSeconds: 0))
        #expect(await harness.fire().status == 202)
        #expect(await harness.fire().status == 202)
        let third = await harness.fire()
        #expect(third.status == 429)
        #expect(Self.errorCode(third) == "rate_limited")
        harness.ingress.resetRateLimits()
        #expect(await harness.fire().status == 202)
    }

    @Test func idempotencyKeyDedupesRedeliveries() async throws {
        let harness = try Harness(webhook: WebhookSourceConfig(verification: .none))
        let first = await harness.fire(headers: ["Idempotency-Key": "delivery-1"])
        #expect(first.status == 202)
        let firstId = try #require(Self.runId(first))
        _ = await harness.settled(firstId)

        let again = await harness.fire(headers: ["Idempotency-Key": "delivery-1"])
        #expect(again.status == 200)
        #expect(Self.json(again)["status"] as? String == "duplicate")
        #expect(Self.json(again)["reason"] as? String == "duplicate_of:\(firstId.uuidString)")

        let other = await harness.fire(headers: ["X-GitHub-Delivery": "delivery-2"])
        #expect(other.status == 202)
        _ = await harness.settled(try #require(Self.runId(other)))
        #expect(harness.fired.count == 2)
    }

    @Test func filteredDeliveryIs200WithoutRunning() async throws {
        let harness = try Harness(
            webhook: WebhookSourceConfig(verification: .none),
            filter: EventFilter(conditions: [EventCondition(path: "webhook.body.action", equals: "closed")]))
        let response = await harness.fire()
        #expect(response.status == 200)
        #expect(Self.json(response)["status"] as? String == "filtered")
        #expect(harness.fired.isEmpty)
    }

    @Test func busySerialEventRefusesWith429() async throws {
        let harness = try Harness(
            webhook: WebhookSourceConfig(verification: .none),
            delivery: EventDeliveryPolicy(mode: .serial, maxQueued: 0, dedupeWindowSeconds: 0))
        harness.holdRuns = true
        let first = await harness.fire()
        #expect(first.status == 202)
        while harness.fired.isEmpty { await Task.yield() }

        let second = await harness.fire()
        #expect(second.status == 429)
        #expect(Self.json(second)["reason"] as? String == "busy")

        harness.release()
        let firstId = try #require(Self.runId(first))
        let run = try #require(await harness.settled(firstId))
        #expect(run.status == .succeeded)
    }

    @Test func queuedFireRunsAfterTheCurrentOne() async throws {
        let harness = try Harness(
            webhook: WebhookSourceConfig(verification: .none),
            delivery: EventDeliveryPolicy(mode: .serial, maxQueued: 1, dedupeWindowSeconds: 0))
        harness.holdRuns = true
        let first = await harness.fire(#"{"n":1}"#)
        while harness.fired.isEmpty { await Task.yield() }
        let second = await harness.fire(#"{"n":2}"#)
        #expect(second.status == 202)
        #expect(Self.json(second)["status"] as? String == "queued")
        let third = await harness.fire(#"{"n":3}"#)
        #expect(third.status == 429)
        #expect(Self.json(third)["reason"] as? String == "queue_full")

        harness.release()
        let firstId = try #require(Self.runId(first))
        let secondId = try #require(Self.runId(second))
        _ = await harness.settled(firstId)
        let secondRun = try #require(await harness.settled(secondId))
        #expect(secondRun.status == .succeeded)
        #expect(harness.fired.map { $0.payload.value(atPath: "webhook.body.n") } == [.number(1), .number(2)])
    }

    // MARK: - Run status

    @Test func runStatusReportsTheRunForItsOwnEventOnly() async throws {
        let harness = try Harness(webhook: WebhookSourceConfig(verification: .none))
        let fired = await harness.fire()
        let runId = try #require(Self.runId(fired))
        _ = await harness.settled(runId)

        let status = await harness.ingress.handleRunStatus(token: harness.token, runId: runId)
        #expect(status.status == 200)
        #expect(Self.json(status)["status"] as? String == "succeeded")
        #expect(Self.json(status)["finished_at"] is String)

        let unknownRun = await harness.ingress.handleRunStatus(token: harness.token, runId: UUID())
        #expect(unknownRun.status == 404)
        #expect(Self.errorCode(unknownRun) == "run_not_found")

        let other = harness.manager.create(
            OsaurusEvent(
                name: "Other hook", source: .webhook(WebhookSourceConfig(verification: .none)),
                action: .agent(AgentEventAction(target: .local(UUID()), instructions: ""))))
        let crossEvent = await harness.ingress.handleRunStatus(token: other.source.webhook!.token, runId: runId)
        #expect(crossEvent.status == 404)

        let unknownToken = await harness.ingress.handleRunStatus(token: "nope", runId: runId)
        #expect(Self.errorCode(unknownToken) == "not_found")
    }

    @Test func rotatedTokenRetiresTheOldURL() async throws {
        let harness = try Harness(webhook: WebhookSourceConfig(verification: .none))
        let oldToken = harness.token
        let newToken = try #require(harness.manager.rotateWebhookToken(harness.event.id))
        #expect(newToken != oldToken)
        let stale = await harness.ingress.handleFire(
            token: oldToken, request: EventWebhookIngressRequest(method: "POST", headers: [:], query: [:], body: Data()))
        #expect(stale.status == 404)
        harness.event = try #require(harness.manager.event(for: harness.event.id))
        #expect(await harness.fire().status == 202)
    }
}
