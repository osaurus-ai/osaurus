//
//  AgentChannelInboundActivityTests.swift
//  osaurusTests
//
//  Tests for per-event inbound stage telemetry, its user-facing guidance,
//  and the native connection-center badge truthfulness.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentChannelInboundActivityTests {

    @Test func activityCenterReturnsNewestFirstAndScopesByConnection() async {
        let center = AgentChannelInboundActivityCenter()
        await center.record(connectionId: "slack", providerEventId: "Ev1", stage: .received)
        await center.record(connectionId: "slack", providerEventId: "Ev1", stage: .stored)
        await center.record(connectionId: "telegram", providerEventId: "Tg1", stage: .received)

        let slack = await center.recent(connectionId: "slack", limit: 10)
        #expect(slack.map(\.stage) == [.stored, .received])
        #expect(slack.allSatisfy { $0.connectionId == "slack" })

        let telegram = await center.recent(connectionId: "telegram", limit: 10)
        #expect(telegram.count == 1)
    }

    @Test func activityCenterTrimsToTheRingCapacity() async {
        let center = AgentChannelInboundActivityCenter()
        for index in 0 ..< (AgentChannelInboundActivityCenter.maxEventsPerConnection + 25) {
            await center.record(
                connectionId: "slack",
                providerEventId: "Ev\(index)",
                stage: .received
            )
        }

        let events = await center.recent(
            connectionId: "slack",
            limit: AgentChannelInboundActivityCenter.maxEventsPerConnection + 50
        )
        #expect(events.count == AgentChannelInboundActivityCenter.maxEventsPerConnection)
        // Oldest entries were dropped, newest kept.
        #expect(events.first?.providerEventId == "Ev124")
        #expect(events.last?.providerEventId == "Ev25")
    }

    @Test func activityCenterFiltersEventsBySinceDateForTheVerifier() async {
        let center = AgentChannelInboundActivityCenter()
        let before = Date(timeIntervalSinceNow: -100)
        await center.record(
            connectionId: "slack",
            providerEventId: "EvOld",
            stage: .received,
            at: before
        )
        let mark = Date(timeIntervalSinceNow: -10)
        await center.record(connectionId: "slack", providerEventId: "EvNew", stage: .received)

        let fresh = await center.events(connectionId: "slack", since: mark)
        #expect(fresh.map(\.providerEventId) == ["EvNew"])
    }

    @Test func guidanceExistsForEveryKnownRejectionAndSuppressionReason() {
        let reasons = [
            "sender_not_allowlisted",
            "channel_not_readable",
            "room_not_allowlisted",
            "team_not_allowlisted",
            "bot_identity_unknown",
            "own_message",
            "duplicate_event",
            "not_a_channel_message",
            "undecodable_envelope",
            "mention_required",
            "inbound_dispatch_disabled",
            "inbound_dispatch_not_configured",
            "inbound_agent_unavailable",
            "conversation_already_running",
            "invalid_dispatch_payload",
            "rate_limited",
        ]
        for reason in reasons {
            let guidance = AgentChannelInboundActivityPresentation.guidance(
                stage: .rejected,
                reason: reason
            )
            #expect(guidance != nil, "Missing recovery text for reason \(reason)")
        }
    }

    @Test func mentionGuidanceExplainsBotUserVersusOsaurusAgentConfusion() {
        let guidance = AgentChannelInboundActivityPresentation.guidance(
            stage: .dispatchSuppressed,
            reason: "mention_required"
        )
        #expect(guidance?.contains("not the Osaurus agent name") == true)
    }

    @Test func failedStageFallsBackToTheRecordedFailureMessage() {
        let guidance = AgentChannelInboundActivityPresentation.guidance(
            stage: .failed,
            reason: "The channel task timed out before producing a reply."
        )
        #expect(guidance == "The channel task timed out before producing a reply.")

        #expect(AgentChannelInboundActivityPresentation.guidance(
            stage: .received,
            reason: nil
        ) == nil)
    }

    @Test func activityEventsNeverStoreUntrimmedReasonsOrEmptyStrings() {
        let event = AgentChannelInboundActivityEvent(
            connectionId: " slack ",
            providerEventId: " Ev1 ",
            stage: .rejected,
            reason: "   "
        )
        #expect(event.connectionId == "slack")
        #expect(event.providerEventId == "Ev1")
        #expect(event.reason == nil)
    }

    // MARK: - Native badge truthfulness

    @MainActor
    @Test func nativeBadgeMirrorsTransportHealthInsteadOfSavedCredentials() {
        func health(_ status: AgentChannelTransportHealthStatus) -> AgentChannelTransportHealthState {
            AgentChannelTransportHealthState(
                connectionId: "slack",
                transportId: "slack_socket_mode",
                provider: .slack,
                status: status,
                severity: .info,
                summary: "test",
                isRunning: status == .healthy,
                receiveEnabled: true
            )
        }

        #expect(AgentChannelConnectionCenterView.nativeBadge(
            configured: false,
            receiveExpected: false,
            health: nil
        ) == .diagnostics(status: "not_configured"))

        // Saved tokens without a running receive transport must not read as
        // a green "Configured".
        #expect(AgentChannelConnectionCenterView.nativeBadge(
            configured: true,
            receiveExpected: true,
            health: nil
        ) == .transportNotRunning)

        // A blocked/disabled transport shows its real state.
        #expect(AgentChannelConnectionCenterView.nativeBadge(
            configured: true,
            receiveExpected: true,
            health: health(.disabled)
        ) == .transport(status: .disabled))

        #expect(AgentChannelConnectionCenterView.nativeBadge(
            configured: true,
            receiveExpected: true,
            health: health(.failed)
        ) == .transport(status: .failed))

        #expect(AgentChannelConnectionCenterView.nativeBadge(
            configured: true,
            receiveExpected: true,
            health: health(.healthy)
        ) == .transport(status: .healthy))

        // Send-only setups without receive credentials keep the plain
        // configured badge.
        #expect(AgentChannelConnectionCenterView.nativeBadge(
            configured: true,
            receiveExpected: false,
            health: nil
        ) == .diagnostics(status: "configured"))
    }

    // MARK: - Card routing summary

    @MainActor
    @Test func routingSummaryDescribesDefaultRoutesAndMissingAgents() {
        let agentA = UUID()
        let agentB = UUID()
        let names: [UUID: String] = [agentA: "Sales", agentB: "Support"]
        func summary(_ dispatch: AgentChannelInboundDispatchConfiguration) -> String? {
            AgentChannelConnectionCenterView.routingSummary(dispatch) { names[$0] }
        }

        // Replying off is stated explicitly on a configured channel rather
        // than hiding the state behind a missing line.
        #expect(summary(AgentChannelInboundDispatchConfiguration(enabled: false)) == "Replies off")

        // Enabled but nothing selected → honest call to action.
        #expect(
            summary(AgentChannelInboundDispatchConfiguration(enabled: true))
                == "Replies on — choose an agent")

        // Single default agent.
        #expect(
            summary(
                AgentChannelInboundDispatchConfiguration(enabled: true, targetAgentId: agentA)
            ) == "Replies: Sales")

        // Default + a route to a second agent → multi-agent summary.
        let multi = AgentChannelInboundDispatchConfiguration(
            enabled: true,
            targetAgentId: agentA,
            routes: [AgentChannelDispatchRoute(roomId: "C1", agentId: agentB)]
        )
        #expect(summary(multi) == "Replies: 2 agents — Sales, Support")

        // A routed agent that no longer exists is still surfaced.
        let missing = AgentChannelInboundDispatchConfiguration(
            enabled: true,
            targetAgentId: UUID()
        )
        #expect(summary(missing) == "Replies: Unknown agent")
    }

    // MARK: - Custom channel badge honesty

    @MainActor
    @Test func customBadgeReflectsUsabilityNotJustEnabledFlag() {
        func connection(
            enabled: Bool,
            actions: [String: AgentChannelCustomHTTPAction],
            writeEnabled: Bool = false
        ) -> AgentChannelConnection {
            AgentChannelConnection(
                id: "webhook",
                name: "Webhook",
                kind: .customHTTP,
                enabled: enabled,
                writeEnabled: writeEnabled,
                customHTTP: AgentChannelCustomHTTPConfiguration(
                    baseURL: "https://example.com",
                    actions: actions
                )
            )
        }
        let action = AgentChannelCustomHTTPAction(path: "/messages")

        let disabled = AgentChannelConnectionCenterView.customBadge(
            for: connection(enabled: false, actions: ["read_messages": action]))
        #expect(disabled.tone == .neutral)

        // Enabled with no actions is not usable and must warn, not show green.
        let empty = AgentChannelConnectionCenterView.customBadge(
            for: connection(enabled: true, actions: [:]))
        #expect(empty.tone == .warning)

        let readOnly = AgentChannelConnectionCenterView.customBadge(
            for: connection(enabled: true, actions: ["read_messages": action]))
        #expect(readOnly.tone == .success)
        #expect(readOnly.label.contains("read-only"))

        let writable = AgentChannelConnectionCenterView.customBadge(
            for: connection(enabled: true, actions: ["send_message": action], writeEnabled: true))
        #expect(writable.tone == .success)
        #expect(!writable.label.contains("read-only"))
    }
}
