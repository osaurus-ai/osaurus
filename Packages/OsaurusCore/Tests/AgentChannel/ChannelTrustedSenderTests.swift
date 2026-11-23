//
//  ChannelTrustedSenderTests.swift
//  osaurusTests
//
//  Trust Allowlisted Senders (#3518): a channel run from an allowlisted
//  sender on a connection that opted in may use Apple app tools; every other
//  externally denied tool stays denied, and trust can never be minted from
//  an untrusted external context.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChannelTrustedSenderTests {

    private static let stillDenied = [
        "agent_channel_send_message", "agent_channel_publish", "file_write", "shell_run",
        PromptWorkingFolderTool.toolName,
    ]

    // MARK: - Surface gate

    @Test func trustedChannelSenderAllowsOnlyAppleAppTools() {
        #expect(AppleApp.allToolNames.contains("calendar_events"))
        for name in Self.stillDenied {
            #expect(ToolRegistry.externallyDeniedToolNames.contains(name), "\(name)")
        }

        let untrusted = ChatExecutionContext.$isExternalSurface.withValue(true) {
            ToolRegistry.isDeniedForCurrentSurface("calendar_events")
        }
        #expect(untrusted)

        ChatExecutionContext.$isExternalSurface.withValue(true) {
            ChatExecutionContext.$isTrustedChannelSender.withValue(true) {
                for name in AppleApp.allToolNames {
                    #expect(!ToolRegistry.isDeniedForCurrentSurface(name), "\(name) should pass for a trusted sender")
                }
                for name in Self.stillDenied {
                    #expect(ToolRegistry.isDeniedForCurrentSurface(name), "\(name) must stay denied")
                }
            }
        }
    }

    // MARK: - Dispatch resolver

    @Test func trustResolvesOnlyWithAnExternalSurface() {
        var trustedChannel = DispatchRequest(prompt: "p", source: .plugin, externalSurface: true)
        trustedChannel.trustedChannelSender = true
        #expect(BackgroundTaskManager.resolvedTrustedChannelSender(for: trustedChannel))

        var notExternal = DispatchRequest(prompt: "p", source: .plugin, externalSurface: false)
        notExternal.trustedChannelSender = true
        #expect(!BackgroundTaskManager.resolvedTrustedChannelSender(for: notExternal))

        let untrusted = DispatchRequest(prompt: "p", source: .plugin, externalSurface: true)
        #expect(!BackgroundTaskManager.resolvedTrustedChannelSender(for: untrusted))
    }

    @Test func trustIsNarrowOnlyInsideAnExternalContext() {
        var claimsTrust = DispatchRequest(prompt: "p", source: .http, externalSurface: true)
        claimsTrust.trustedChannelSender = true
        // An HTTP/MCP run (external, untrusted) dispatching a request that
        // claims trust must not gain it.
        let minted = ChatExecutionContext.$isExternalSurface.withValue(true) {
            BackgroundTaskManager.resolvedTrustedChannelSender(for: claimsTrust)
        }
        #expect(!minted)

        // A trusted channel run's own dispatch keeps it.
        let plain = DispatchRequest(prompt: "p", source: .delegation, externalSurface: false)
        let inherited = ChatExecutionContext.$isExternalSurface.withValue(true) {
            ChatExecutionContext.$isTrustedChannelSender.withValue(true) {
                BackgroundTaskManager.resolvedTrustedChannelSender(for: plain)
            }
        }
        #expect(inherited)
    }

    @Test func queuedChildRequestRestoresBothFlagsOutsideParentLocals() async {
        // The scheduler starts a queued child with no parent task locals:
        // only the request carries the surface.
        var child = DispatchRequest(prompt: "p", source: .delegation, externalSurface: true)
        child.trustedChannelSender = true
        let external = BackgroundTaskManager.resolvedExternalSurface(for: child)
        let trusted = BackgroundTaskManager.resolvedTrustedChannelSender(for: child)
        #expect(external && trusted)

        let observed = await Self.surfaceVerdicts(external: external, trusted: trusted)
        #expect(observed.calendar == false)
        #expect(observed.fileWrite == true)

        let untrustedChild = DispatchRequest(prompt: "p", source: .delegation, externalSurface: true)
        let denied = await Self.surfaceVerdicts(
            external: BackgroundTaskManager.resolvedExternalSurface(for: untrustedChild),
            trusted: BackgroundTaskManager.resolvedTrustedChannelSender(for: untrustedChild))
        #expect(denied.calendar == true)
    }

    @Test func surfaceBindingNeverTrustsAnInAppRun() async {
        let observed = await Self.surfaceVerdicts(external: false, trusted: true)
        #expect(observed.trusted == false)
        #expect(observed.calendar == false && observed.fileWrite == false)
    }

    private static func surfaceVerdicts(
        external: Bool, trusted: Bool
    ) async -> (calendar: Bool, fileWrite: Bool, trusted: Bool) {
        var result = (calendar: false, fileWrite: false, trusted: false)
        await BackgroundTaskManager.withSurface(external: external, trustedChannelSender: trusted) {
            // An unstructured task, like the one `ChatSession.send` starts.
            result = await Task {
                (
                    ToolRegistry.isDeniedForCurrentSurface("calendar_events"),
                    ToolRegistry.isDeniedForCurrentSurface("file_write"),
                    ChatExecutionContext.isTrustedChannelSender
                )
            }.value
        }
        return result
    }

    private static func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    @Test func delegationCarriesParentSurfaceOnTheRequest() throws {
        let source = try Self.source("Services/AgentDelegation/AgentDelegationDispatcher.swift")
        #expect(source.contains("externalSurface: ChatExecutionContext.isExternalSurface,"))
        #expect(source.contains("request.trustedChannelSender = ChatExecutionContext.isTrustedChannelSender"))
    }

    /// Integration tripwire for the hand-offs between the gate decision and
    /// the dispatched run: each provider forwards its gate's verdict, and
    /// the relay puts it on both the new run and steered follow-ups.
    @Test func gateVerdictReachesTheDispatchedRun() throws {
        for provider in ["Telegram", "Discord", "IMessage", "WhatsApp", "Slack"] {
            let source = try Self.source("Services/\(provider)/\(provider)ConnectionService.swift")
            #expect(source.contains("authorization.senderTrusted"), "\(provider)")
        }
        let relay = try Self.source("Services/AgentChannel/AgentChannelInboundRelay.swift")
        #expect(relay.contains("dispatch.trustedChannelSender = request.senderTrusted"))
        #expect(relay.components(separatedBy: "trustedChannelSender: request.senderTrusted").count - 1 == 2)
        #expect(!relay.contains("taskManager.submitQuickReply("))
        let events = try Self.source("Services/Event/ChannelMessageEventSource.swift")
        #expect(events.contains("senderTrusted: message.senderTrusted"))
    }

    // MARK: - Refusal text

    @Test func appleToolDenialIsNonRetryableAndNamesTheSetting() throws {
        let envelope = ToolRegistry.externalSurfaceDenialEnvelope(tool: "calendar_events")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
        #expect(object["retryable"] as? Bool == false)
        let message = try #require(object["message"] as? String)
        #expect(message.contains("Trust Allowlisted Senders"))
        #expect(message.contains("'calendar_events'"))

        let other = ToolRegistry.externalSurfaceDenialMessage(tool: "file_write")
        #expect(!other.contains("Trust Allowlisted Senders"))
        #expect(other.contains("only run from the Osaurus app"))
    }

    // MARK: - Configuration

    @Test func nativeConfigurationsDefaultTrustOffAndRoundTrip() throws {
        try Self.checkTrustField(TelegramConnectionConfiguration(), on: TelegramConnectionConfiguration(trustAllowlistedSenders: true))
        try Self.checkTrustField(SlackConnectionConfiguration(), on: SlackConnectionConfiguration(trustAllowlistedSenders: true))
        try Self.checkTrustField(DiscordConnectionConfiguration(), on: DiscordConnectionConfiguration(trustAllowlistedSenders: true))
        try Self.checkTrustField(IMessageConnectionConfiguration(), on: IMessageConnectionConfiguration(trustAllowlistedSenders: true))
        try Self.checkTrustField(WhatsAppConnectionConfiguration(), on: WhatsAppConnectionConfiguration(trustAllowlistedSenders: true))
        try Self.checkTrustField(
            AgentChannelInboundAuthorizationPolicy(),
            on: AgentChannelInboundAuthorizationPolicy(trustAllowlistedSenders: true))
    }

    /// A stored file written before the field existed decodes with trust
    /// off, and a saved `true` survives a round trip.
    private static func checkTrustField<T: Codable & Equatable>(_ off: T, on: T) throws {
        let encoded = try JSONEncoder().encode(on)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(legacy["trustAllowlistedSenders"] as? Bool == true, "\(T.self)")
        legacy.removeValue(forKey: "trustAllowlistedSenders")
        let decodedLegacy = try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: legacy))
        let reencoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decodedLegacy)) as? [String: Any])
        #expect(reencoded["trustAllowlistedSenders"] as? Bool == false, "\(T.self)")
        #expect(try JSONDecoder().decode(T.self, from: encoded) == on, "\(T.self)")
        #expect(off != on, "\(T.self)")
    }

    @Test func senderTrustKindsExcludeUnverifiableSenders() {
        let kinds = AgentChannelInboundAuthorizationPolicy.senderTrustKinds
        #expect(kinds == [.telegram, .slack, .discord, .imessage, .whatsapp])
        #expect(!kinds.contains(.email))
        #expect(!kinds.contains(.n8n))
        #expect(!kinds.contains(.customHTTP))
    }

    @Test func refusedDecisionIsNeverTrusted() {
        let refused = AgentChannelInboundAuthorizationDecision(
            decision: .deny, shouldDispatch: false, reason: "sender_not_allowlisted",
            auditDecisionReason: "test", connectionId: "telegram", roomId: "r", senderTrusted: true)
        #expect(!refused.senderTrusted)
        #expect(refused.dictionary["sender_trusted"] == nil)

        let allowed = AgentChannelInboundAuthorizationDecision(
            decision: .allow, shouldDispatch: true, reason: "allowed",
            auditDecisionReason: "test", connectionId: "telegram", roomId: "r", senderTrusted: true)
        #expect(allowed.senderTrusted)
        #expect(allowed.dictionary["sender_trusted"] as? Bool == true)
    }
}
