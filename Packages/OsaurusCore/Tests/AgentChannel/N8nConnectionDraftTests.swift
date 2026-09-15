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
        // Legacy row without a stored location: plaintext implies LAN.
        #expect(draft.callerLocation == .lan)
        #expect(draft.idWasEdited)
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
        // The inferred location is persisted on the next save.
        #expect(rebuilt.n8n?.callerLocation == .lan)
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
        // No location chosen yet: a new, non-plaintext draft is This Mac.
        #expect(built.n8n?.callerLocation == .thisMac)
        #expect(built.n8n?.outbound.isConfigured == false)
        #expect(built.n8n?.outbound.signBodies == true)
        #expect(built.n8n?.inboundDispatch.enabled == false)
    }

    @Test func callerLocationRoundTripsAndOwnsThePlaintextDecision() throws {
        var draft = N8nConnectionDraft()
        draft.id = "n8n-remote"
        draft.callerLocation = .remote
        // The sheet clears this when leaving LAN; the model also refuses to
        // persist plaintext for a non-LAN location.
        draft.plaintextAllowed = true
        let remote = draft.connection()
        #expect(remote.n8n?.callerLocation == .remote)
        #expect(remote.n8n?.remoteTransportPolicy == .secureChannelRequired)

        let reopened = N8nConnectionDraft(connection: remote)
        #expect(reopened.callerLocation == .remote)
        #expect(!reopened.plaintextAllowed)

        draft.callerLocation = .lan
        let lan = draft.connection()
        #expect(lan.n8n?.callerLocation == .lan)
        #expect(lan.n8n?.remoteTransportPolicy == .plaintextAllowed)

        // Persisted JSON carries the field and older rows decode without it.
        let data = try JSONEncoder().encode(remote)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"callerLocation\":\"remote\""))
        let legacy = try JSONDecoder().decode(
            AgentChannelN8nConfiguration.self,
            from: Data(#"{"inboundVerification":{"method":"hmac_sha256"},"remoteTransportPolicy":"plaintext_allowed"}"#.utf8)
        )
        #expect(legacy.callerLocation == nil)
        #expect(legacy.effectiveCallerLocation == .lan)
        #expect(AgentChannelN8nConfiguration().effectiveCallerLocation == .thisMac)
    }

    /// A pre-redesign Secure-Channel row could have been This Mac, Docker
    /// or a relay-only Remote setup; the draft must not guess, or a Remote
    /// user reopening the sheet would be handed a loopback-only code.
    @Test func legacySecureChannelConnectionLeavesTheLocationUnanswered() {
        var stored = Self.connection()
        stored.n8n?.remoteTransportPolicy = .secureChannelRequired
        stored.n8n?.callerLocation = nil

        let draft = N8nConnectionDraft(connection: stored)
        #expect(!draft.isNew)
        #expect(draft.callerLocation == nil)
        #expect(!draft.plaintextAllowed)

        // Plaintext is only ever offered for LAN, so that legacy signal is safe to pre-select.
        var lanLegacy = Self.connection()
        lanLegacy.n8n?.callerLocation = nil
        #expect(lanLegacy.n8n?.remoteTransportPolicy == .plaintextAllowed)
        #expect(N8nConnectionDraft(connection: lanLegacy).callerLocation == .lan)

        // A stored location always wins over inference.
        var remote = Self.connection()
        remote.n8n?.remoteTransportPolicy = .secureChannelRequired
        remote.n8n?.callerLocation = .remote
        #expect(N8nConnectionDraft(connection: remote).callerLocation == .remote)
    }

    @Test func connectionIdSlugFollowsTheDisplayName() {
        #expect(N8nConnectionSlug.make(from: "Accounting Channel") == "n8n-accounting-channel")
        #expect(N8nConnectionSlug.make(from: "  Café  Ops!!  ") == "n8n-cafe-ops")
        #expect(N8nConnectionSlug.make(from: "n8n-already-prefixed") == "n8n-already-prefixed")
        #expect(N8nConnectionSlug.make(from: "N8N") == "n8n")
        #expect(N8nConnectionSlug.make(from: "") == "")
        #expect(N8nConnectionSlug.make(from: "!!!") == "")
        // Every slug is a valid, already-normalized connection id.
        for name in ["Accounting Channel", "Café Ops", "a__b--c"] {
            let slug = N8nConnectionSlug.make(from: name)
            #expect(AgentChannelConnection.normalizedId(slug) == slug)
        }
        // A fresh draft has an untouched id; a loaded one is considered edited.
        #expect(!N8nConnectionDraft().idWasEdited)
        #expect(N8nConnectionDraft(connection: Self.connection()).idWasEdited)
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

        // Empty allowlists are the expected state before the first workflow
        // is approved, so they read as waiting rather than as a warning.
        connection.inboundAuthorization.senderAllowlist = []
        let noSenders = AgentChannelConnectionCenterView.customBadge(for: connection)
        #expect(noSenders.label == L("Waiting for first workflow"))
        #expect(noSenders.tone == .neutral)

        // A pending first-contact request outranks everything but Disabled.
        let pending = AgentChannelConnectionCenterView.customBadge(for: connection, pendingApprovals: 2)
        // The view formats `L("\(n) waiting for approval")`; the English render is pinned here.
        #expect(pending.label == "2 waiting for approval")
        #expect(pending.tone == .warning)

        connection.n8n?.inboundDispatch = AgentChannelInboundDispatchConfiguration()
        let noAgent = AgentChannelConnectionCenterView.customBadge(for: connection)
        #expect(noAgent.label == L("No agent assigned"))
        #expect(noAgent.tone == .warning)

        connection.enabled = false
        #expect(AgentChannelConnectionCenterView.customBadge(for: connection).label == L("Disabled"))
        #expect(
            AgentChannelConnectionCenterView.customBadge(for: connection, pendingApprovals: 1).label == L("Disabled")
        )
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
        // Everything the pairing code needs (id, location, bound agent + relay)
        // precedes Pair; allowlists are filled by first contact in Prove it.
        #expect(ids == ["basics", "location", "reply", "connect", "live"])
        #expect(N8nSetupSection.requiredSectionIds == ["basics", "location", "reply", "connect"])
        #expect(N8nSetupSection.fallbackSectionId == "live")
        #expect(N8nSetupSection.basics.title == L("Name it"))
        #expect(N8nSetupSection.location.title == L("Where is your n8n?"))
        #expect(N8nSetupSection.howOsaurusReplies.title == L("Who answers?"))
        #expect(N8nSetupSection.connect.title == L("Pair"))
        #expect(N8nSetupSection.liveCheck.title == L("Prove it"))
        #expect(N8nSetupSection.connect.caption == L("Pairing code"))
        #expect(N8nSetupSection.location.caption == L("This Mac, Docker, LAN, or remote"))
        #expect(N8nSetupSection.liveCheck.caption == L("Approve workflows, verify"))
        // Discord/Telegram captions must not appear on the n8n rail.
        for section in N8nSetupSection.sections {
            #expect(section.caption != L("Bot and tokens"))
            #expect(section.caption != L("Rooms and people"))
        }
    }

    @Test func callerLocationCopyExplainsTheConsequence() {
        #expect(AgentChannelN8nCallerLocation.allCases.map(\.rawValue) == ["this_mac", "docker_desktop", "lan", "remote"])
        #expect(AgentChannelN8nCallerLocation.remote.summary.contains("relay"))
        #expect(AgentChannelN8nCallerLocation.lan.summary.contains("exposed"))
        #expect(AgentChannelN8nCallerLocation.dockerDesktop.summary.contains("host.docker.internal"))
        #expect(AgentChannelN8nCallerLocation.inferred(plaintextAllowed: true) == .lan)
        #expect(AgentChannelN8nCallerLocation.inferred(plaintextAllowed: false) == .thisMac)
    }

    @Test func recipeMatchesLocationAndAllowlists() {
        let envelope = N8nSetupRecipe.sampleEnvelope(conversationId: "n8n-test", senderId: "tpae")
        #expect(envelope.contains("\"conversation_id\":\"n8n-test\""))
        #expect(envelope.contains("\"sender\":{\"id\":\"tpae\"}"))

        let docker = N8nSetupRecipe.inboundURL(
            connectionId: "n8n-local",
            port: 1337,
            location: .dockerDesktop
        )
        #expect(docker == "http://host.docker.internal:1337/channels/n8n/n8n-local/inbound")

        let lan = N8nSetupRecipe.inboundURL(
            connectionId: "n8n-local",
            port: 1337,
            location: .lan
        )
        #expect(lan == "http://<this-mac-ip>:1337/channels/n8n/n8n-local/inbound")

        let remote = N8nSetupRecipe.pollURL(
            connectionId: "n8n-local",
            port: 1337,
            location: .remote,
            relayURL: "https://0xabc.agent.osaurus.ai/"
        )
        #expect(remote == "https://0xabc.agent.osaurus.ai/channels/n8n/n8n-local/tasks/{task_id}")
        let remotePlaceholder = N8nSetupRecipe.inboundURL(connectionId: "n8n-local", port: 1337, location: .remote)
        #expect(remotePlaceholder == "https://<relay-url>/channels/n8n/n8n-local/inbound")

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
