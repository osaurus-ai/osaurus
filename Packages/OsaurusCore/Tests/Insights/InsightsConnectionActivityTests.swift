//
//  InsightsConnectionActivityTests.swift
//  osaurusTests
//
//  Pins the connection-attribution surface added for the Remote Agent UX
//  polish: `RequestLog` carries a `RequestConnectionInfo` (provider/relay,
//  transport, mode, and — for inbound host traffic — the paired access key),
//  and `InsightsService` can summarize inbound/outbound usage filtered by
//  accessKeyId, audience, or providerId. These power the host-side
//  "Remote Connections" view and the `RemoteAgentDetailView` activity card.
//
//  `InsightsService.shared` is a process-wide singleton, so every log is
//  tagged with a per-test-unique accessKeyId / providerId / audience and
//  looked up by that tag — other suites running in parallel can prepend their
//  own rows into the shared ring buffer between insert and assertion.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Insights connection activity", .serialized)
struct InsightsConnectionActivityTests {

    private func inboundLog(
        keyId: String,
        audience: String,
        outputTokens: Int,
        durationMs: Double,
        timestamp: Date
    ) -> RequestLog {
        RequestLog(
            timestamp: timestamp,
            source: .httpAPI,
            method: "POST",
            path: "/chat/completions",
            statusCode: 200,
            durationMs: durationMs,
            model: "peer/model",
            inputTokens: 5,
            outputTokens: outputTokens,
            connection: RequestConnectionInfo(
                transport: .secureChannel,
                mode: .remoteAgentRun,
                accessKeyId: keyId,
                audience: audience
            )
        )
    }

    // MARK: - RequestConnectionInfo / RequestLog plumbing

    @Test func requestLog_dropsEmptyConnectionInfo() {
        let log = RequestLog(
            source: .chatUI,
            method: "POST",
            path: "/chat/completions",
            statusCode: 200,
            durationMs: 10,
            connection: RequestConnectionInfo()
        )
        // An all-nil connection is normalized to nil so the Insights detail
        // pane doesn't render an empty "Connection" section.
        #expect(log.connection == nil)
    }

    @Test func requestLog_keepsPopulatedConnectionInfo() {
        let providerId = UUID()
        let log = RequestLog(
            source: .chatUI,
            method: "POST",
            path: "/agents/addr/run",
            statusCode: 200,
            durationMs: 10,
            connection: RequestConnectionInfo(
                providerId: providerId,
                remoteEndpoint: "https://relay/agents/addr/run",
                transport: .secureChannel,
                mode: .remoteAgentRun
            )
        )
        #expect(log.connection?.providerId == providerId)
        #expect(log.connection?.mode == .remoteAgentRun)
        #expect(log.connection?.transport == .secureChannel)
    }

    // MARK: - activity(forAccessKeyId:)

    @Test func activity_byAccessKeyId_aggregatesOnlyMatchingRows() {
        let keyId = "key-\(UUID().uuidString)"
        let otherKey = "key-\(UUID().uuidString)"
        let aud = "agent-\(UUID().uuidString)"
        let base = Date()

        // Two rows for our key (10 + 30 tok/s), one row for a different key.
        InsightsService.shared.log(
            inboundLog(
                keyId: keyId,
                audience: aud,
                outputTokens: 10,
                durationMs: 1000,
                timestamp: base
            )
        )
        let newest = base.addingTimeInterval(60)
        InsightsService.shared.log(
            inboundLog(
                keyId: keyId,
                audience: aud,
                outputTokens: 30,
                durationMs: 1000,
                timestamp: newest
            )
        )
        InsightsService.shared.log(
            inboundLog(
                keyId: otherKey,
                audience: aud,
                outputTokens: 99,
                durationMs: 1000,
                timestamp: base
            )
        )

        let activity = InsightsService.shared.activity(forAccessKeyId: keyId)
        #expect(activity.requestCount == 2)
        #expect(activity.totalOutputTokens == 40)
        // (10 + 30) / 2
        #expect(abs(activity.averageSpeed - 20.0) < 0.001)
        #expect(activity.lastUsed == newest)
        #expect(!activity.isEmpty)
    }

    @Test func activity_byAccessKeyId_emptyForUnknownKey() {
        let activity = InsightsService.shared.activity(
            forAccessKeyId: "key-never-logged-\(UUID().uuidString)"
        )
        #expect(activity.isEmpty)
        #expect(activity.requestCount == 0)
        #expect(activity.lastUsed == nil)
    }

    @Test func activity_byAccessKeyId_blankIsEmpty() {
        #expect(InsightsService.shared.activity(forAccessKeyId: "   ").isEmpty)
    }

    // MARK: - activity(forAudience:)

    @Test func activity_byAudience_aggregatesAcrossKeys() {
        let aud = "agent-\(UUID().uuidString)"
        let keyA = "key-\(UUID().uuidString)"
        let keyB = "key-\(UUID().uuidString)"
        let base = Date()

        InsightsService.shared.log(
            inboundLog(
                keyId: keyA,
                audience: aud,
                outputTokens: 10,
                durationMs: 1000,
                timestamp: base
            )
        )
        InsightsService.shared.log(
            inboundLog(
                keyId: keyB,
                audience: aud,
                outputTokens: 20,
                durationMs: 1000,
                timestamp: base
            )
        )

        // Audience aggregates inbound traffic across every key scoped to it —
        // the host-side fallback before per-key attribution lands.
        let activity = InsightsService.shared.activity(forAudience: aud)
        #expect(activity.requestCount == 2)
        #expect(activity.totalOutputTokens == 30)
    }

    // MARK: - activity(forProviderId:)

    @Test func activity_byProviderId_aggregatesOutboundRows() {
        let providerId = UUID()
        let base = Date()
        for tokens in [10, 50] {
            InsightsService.shared.log(
                RequestLog(
                    timestamp: base,
                    source: .chatUI,
                    method: "POST",
                    path: "/agents/addr/run",
                    statusCode: 200,
                    durationMs: 1000,
                    model: "peer/model",
                    inputTokens: 5,
                    outputTokens: tokens,
                    connection: RequestConnectionInfo(
                        providerId: providerId,
                        transport: .secureChannel,
                        mode: .remoteAgentRun
                    )
                )
            )
        }

        let activity = InsightsService.shared.activity(forProviderId: providerId)
        #expect(activity.requestCount == 2)
        #expect(activity.totalOutputTokens == 60)
    }

    // MARK: - focus(accessKeyId:)

    @Test func focusByAccessKeyId_targetsMatchingLog() {
        let keyId = "key-\(UUID().uuidString)"
        let log = inboundLog(
            keyId: keyId,
            audience: "agent-\(UUID().uuidString)",
            outputTokens: 7,
            durationMs: 700,
            timestamp: Date()
        )
        InsightsService.shared.log(log)

        #expect(InsightsService.shared.focus(accessKeyId: keyId) == true)
        #expect(InsightsService.shared.pendingFocusLogId == log.id)
        #expect(
            InsightsService.shared.focus(accessKeyId: "key-missing-\(UUID().uuidString)")
                == false
        )
    }
}
