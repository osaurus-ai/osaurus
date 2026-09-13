//
//  N8nConnectionDraftTests.swift
//  osaurus
//
//  Tests for the n8n setup sheet's draft model: connection <-> draft round
//  trip, the fields the sheet forces (kind, space, requireMention) and the
//  Connection Center badge derived from a stored row.
//

import Foundation
import Testing

@testable import OsaurusCore

struct N8nConnectionDraftTests {
    private static let agentId = UUID()

    private static func connection() -> AgentChannelConnection {
        AgentChannelConnection(
            id: "n8n-local",
            name: "n8n local",
            kind: .n8n,
            enabled: true,
            supportedActions: [.diagnostics],
            spaceAllowlist: [AgentChannelN8nConfiguration.spaceId],
            inboundAuthorization: AgentChannelInboundAuthorizationPolicy(
                senderAllowlist: ["tpae", "workflow"],
                roomAllowlist: ["n8n-test"],
                allowBotMessages: true
            ),
            n8n: AgentChannelN8nConfiguration(
                inboundVerification: AgentChannelN8nInboundVerification(
                    method: .sharedSecretHeader,
                    headerName: "X-Custom-Secret"
                ),
                secretName: "webhook",
                inboundDispatch: AgentChannelInboundDispatchConfiguration(
                    enabled: true,
                    targetAgentId: agentId,
                    routes: [],
                    requireMention: true,
                    continueThreads: true,
                    autoReplyEnabled: true
                ),
                remoteTransportPolicy: .plaintextAllowed,
                outbound: AgentChannelN8nOutboundConfiguration(
                    webhookURL: "https://n8n.example.com/webhook/reply",
                    signBodies: false
                )
            )
        )
    }

    @Test func connectionRoundTripsThroughTheDraft() {
        let original = Self.connection()
        let draft = N8nConnectionDraft(connection: original)

        #expect(!draft.isNew)
        #expect(draft.originalId == "n8n-local")
        #expect(draft.verificationMethod == .sharedSecretHeader)
        #expect(draft.verificationHeaderName == "X-Custom-Secret")
        #expect(draft.plaintextAllowed)
        #expect(draft.conversationAllowlistText == "n8n-test")
        #expect(draft.senderAllowlistText == "tpae\nworkflow")
        #expect(draft.allowBotMessages)
        #expect(draft.inboundDispatchEnabled)
        #expect(draft.inboundTarget == .local(Self.agentId))
        #expect(draft.inboundAutoReplyEnabled)
        #expect(draft.outboundWebhookURL == "https://n8n.example.com/webhook/reply")
        #expect(!draft.outboundSignBodies)
        #expect(draft.keychainPluginId == "osaurus.agent-channel.n8n-local")

        let rebuilt = draft.connection()
        #expect(rebuilt.id == original.id)
        #expect(rebuilt.name == original.name)
        #expect(rebuilt.kind == .n8n)
        #expect(rebuilt.spaceAllowlist == [AgentChannelN8nConfiguration.spaceId])
        #expect(rebuilt.inboundAuthorization.senderAllowlist == ["tpae", "workflow"])
        #expect(rebuilt.inboundAuthorization.roomAllowlist == ["n8n-test"])
        #expect(rebuilt.inboundAuthorization.allowBotMessages)
        #expect(rebuilt.n8n?.inboundVerification == original.n8n?.inboundVerification)
        #expect(rebuilt.n8n?.remoteTransportPolicy == .plaintextAllowed)
        #expect(rebuilt.n8n?.outbound == original.n8n?.outbound)
        #expect(rebuilt.n8n?.inboundDispatch.target == .local(Self.agentId))
        #expect(rebuilt.n8n?.inboundDispatch.autoReplyEnabled == true)
        // The sheet never lets n8n require a mention; the model forces it off.
        #expect(rebuilt.n8n?.inboundDispatch.requireMention == false)
    }

    @Test func newDraftBuildsAPollOnlyConnectionWithSafeDefaults() {
        var draft = N8nConnectionDraft()
        draft.id = "  N8N Local  "
        draft.conversationAllowlistText = "n8n-test, ops\n\n"
        draft.senderAllowlistText = "tpae"

        #expect(draft.isNew)
        let built = draft.connection()
        #expect(built.id == AgentChannelConnection.normalizedId("N8N Local"))
        // Empty display name falls back to the id.
        #expect(built.name == built.id)
        #expect(built.enabled)
        #expect(built.supportedActions == [.diagnostics])
        #expect(built.customHTTP == nil)
        #expect(!built.writeEnabled)
        #expect(built.inboundAuthorization.roomAllowlist == ["n8n-test", "ops"])
        #expect(built.n8n?.inboundVerification.method == .hmacSHA256)
        #expect(built.n8n?.inboundVerification.headerName == nil)
        #expect(built.n8n?.remoteTransportPolicy == .secureChannelRequired)
        #expect(built.n8n?.outbound.isConfigured == false)
        #expect(built.n8n?.outbound.signBodies == true)
        #expect(built.n8n?.inboundDispatch.enabled == false)
    }

    @Test func connectionCenterBadgeReflectsAuthorizationDispatchAndPush() {
        var connection = Self.connection()
        #expect(
            AgentChannelConnectionCenterView.customBadge(for: connection).label == L("Enabled (push + poll)")
        )

        connection.n8n?.outbound = AgentChannelN8nOutboundConfiguration()
        #expect(
            AgentChannelConnectionCenterView.customBadge(for: connection).label == L("Enabled (poll replies)")
        )

        connection.n8n?.inboundDispatch = AgentChannelInboundDispatchConfiguration()
        let noAgent = AgentChannelConnectionCenterView.customBadge(for: connection)
        #expect(noAgent.label == L("No agent assigned"))
        #expect(noAgent.tone == .warning)

        connection.inboundAuthorization.senderAllowlist = []
        let noSenders = AgentChannelConnectionCenterView.customBadge(for: connection)
        #expect(noSenders.label == L("No allowed senders"))
        #expect(noSenders.tone == .warning)

        connection.enabled = false
        #expect(AgentChannelConnectionCenterView.customBadge(for: connection).label == L("Disabled"))
    }
}
