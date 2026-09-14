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
        #expect(draft.topology == .lan)
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
            AgentChannelConnectionCenterView.customBadge(for: connection).label
                == "\(L("Header")) · \(L("Enabled (push + poll)"))"
        )

        connection.n8n?.outbound = AgentChannelN8nOutboundConfiguration()
        #expect(
            AgentChannelConnectionCenterView.customBadge(for: connection).label
                == "\(L("Header")) · \(L("Enabled (poll replies)"))"
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

    @Test func connectionCenterBadgeIncludesVerifyModeAndKillSwitch() {
        var hmac = Self.connection()
        hmac.n8n?.inboundVerification = AgentChannelN8nInboundVerification(method: .hmacSHA256)
        #expect(
            AgentChannelConnectionCenterView.n8nBadge(for: hmac, writesEnabled: true).label
                == "\(L("HMAC")) · \(L("Enabled (push + poll)"))"
        )

        let blocked = AgentChannelConnectionCenterView.n8nBadge(for: hmac, writesEnabled: false)
        #expect(blocked.label == "\(L("HMAC")) · \(L("Push blocked"))")
        #expect(blocked.tone == .warning)

        hmac.n8n?.outbound = AgentChannelN8nOutboundConfiguration()
        hmac.writeEnabled = false
        #expect(
            AgentChannelConnectionCenterView.n8nBadge(for: hmac, writesEnabled: false).label
                == "\(L("HMAC")) · \(L("Enabled (poll replies)"))"
        )
    }

    @Test func setupRailIsN8nShapedAndDoesNotReuseDiscordCaptions() {
        let ids = N8nSetupSection.sections.map(\.id)
        // Everything the pairing code needs (id, bound agent) precedes Connect n8n.
        #expect(ids == ["basics", "who", "reply", "connect", "live"])
        #expect(N8nSetupSection.requiredSectionIds == ["basics", "connect", "who"])
        #expect(N8nSetupSection.fallbackSectionId == "live")
        #expect(N8nSetupSection.basics.title == L("Name this channel"))
        #expect(N8nSetupSection.connect.title == L("Connect n8n"))
        #expect(N8nSetupSection.connect.caption == L("Pairing code"))
        #expect(N8nSetupSection.whoMaySpeak.caption == L("Allowlists"))
        #expect(N8nSetupSection.howOsaurusReplies.caption == L("Agent, poll or push"))
        #expect(N8nSetupSection.liveCheck.caption == L("Verify"))
        // Discord/Telegram captions must not appear on the n8n rail.
        for section in N8nSetupSection.sections {
            #expect(section.caption != L("Bot and tokens"))
            #expect(section.caption != L("Rooms and people"))
        }
    }

    @Test func recipeMatchesTopologyAndAllowlists() {
        let envelope = N8nSetupRecipe.sampleEnvelope(conversationId: "n8n-test", senderId: "tpae")
        #expect(envelope.contains("\"conversation_id\":\"n8n-test\""))
        #expect(envelope.contains("\"sender\":{\"id\":\"tpae\"}"))

        let docker = N8nSetupRecipe.inboundURL(
            connectionId: "n8n-local",
            port: 1337,
            topology: .dockerDesktop
        )
        #expect(docker == "http://host.docker.internal:1337/channels/n8n/n8n-local/inbound")

        let lan = N8nSetupRecipe.inboundURL(
            connectionId: "n8n-local",
            port: 1337,
            topology: .lan
        )
        #expect(lan == "http://<this-mac-ip>:1337/channels/n8n/n8n-local/inbound")

        let hmac = N8nSetupRecipe.httpRequestRecipe(
            inboundURL: docker,
            headerName: "X-Osaurus-Channel-Signature",
            method: .hmacSHA256
        )
        #expect(hmac.contains("POST \(docker)"))
        #expect(hmac.contains("Content-Type: application/json"))
        #expect(hmac.contains("X-Osaurus-Channel-Signature: sha256="))

        let snippet = N8nSetupRecipe.hmacCodeSnippet()
        #expect(snippet.contains("createHmac('sha256'"))
        #expect(snippet.contains(".update('')"))

        let curl = N8nSetupRecipe.curlExample(
            inboundURL: docker,
            headerName: "X-Osaurus-Channel-Signature",
            method: .hmacSHA256,
            conversationId: "n8n-test",
            senderId: "tpae"
        )
        #expect(curl.contains(docker))
        #expect(curl.contains("openssl dgst -sha256 -hmac"))
    }

    @Test func catalogTaglineIsN8nShaped() {
        #expect(
            AgentChannelAddCatalog.tagline(for: .n8n)
                == L("Guided setup — n8n HTTP Request in, poll or webhook out")
        )
    }
}
