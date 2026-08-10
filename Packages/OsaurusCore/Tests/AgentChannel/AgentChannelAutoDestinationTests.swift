//
//  AgentChannelAutoDestinationTests.swift
//  OsaurusCoreTests
//
//  Zero-config proactive destinations: derivation correctness from the
//  native channel setup (writable rooms × answering agents), stored-binding
//  precedence, the confirm-only invariant, disappearance when write access
//  or an allowlist entry is removed, stable automatic ids, prompt-section
//  visibility, and end-to-end publish + queued-approval refusal through
//  `AgentChannelPublishService` using an automatic binding id.
//

import Foundation
import Testing
@testable import OsaurusCore

private let agentA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
private let agentB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

private func makeSource(
    connectionId: String = "discord",
    displayName: String = "Discord",
    hasCredential: Bool = true,
    writeEnabled: Bool = true,
    writableRoomIds: [String] = ["room-1"],
    dispatchEnabled: Bool = true,
    defaultAgent: UUID? = agentA,
    routes: [AgentChannelDispatchRoute] = []
) -> AgentChannelAutoDestinationSource {
    AgentChannelAutoDestinationSource(
        connectionId: connectionId,
        displayName: displayName,
        hasCredential: hasCredential,
        writeEnabled: writeEnabled,
        writableRoomIds: writableRoomIds,
        dispatch: AgentChannelInboundDispatchConfiguration(
            enabled: dispatchEnabled,
            targetAgentId: defaultAgent,
            routes: routes
        )
    )
}

private func makeStoredBinding(
    id: String = "custom-room",
    agentId: UUID = agentA,
    connectionId: String = "discord",
    roomId: String = "room-1",
    outboundMode: AgentChannelBindingOutboundMode = .off,
    enabled: Bool = true
) -> AgentChannelBinding {
    AgentChannelBinding(
        id: id,
        agentId: agentId,
        connectionId: connectionId,
        roomId: roomId,
        label: "Custom",
        allowedSources: AgentChannelBindingRunSource.allCases,
        outboundMode: outboundMode,
        enabled: enabled
    )
}

@Suite("AgentChannelAutoDestinationResolver")
struct AgentChannelAutoDestinationResolverTests {

    @Test
    func derivesConfirmBindingPerWritableRoomAndAnsweringAgent() {
        let source = makeSource(
            writableRoomIds: ["room-1", "room-2"],
            defaultAgent: agentA,
            routes: [AgentChannelDispatchRoute(roomId: "room-2", agentId: agentB)]
        )
        let derived = AgentChannelAutoDestinationResolver.derivedBindings(
            sources: [source],
            storedBindings: []
        )

        // room-1 answers as agentA only; room-2 as agentA (default) + agentB
        // (room-scoped route).
        #expect(derived.count == 3)
        let routes = Set(derived.map { "\($0.roomId)|\($0.agentId.uuidString)" })
        #expect(
            routes == [
                "room-1|\(agentA.uuidString)",
                "room-2|\(agentA.uuidString)",
                "room-2|\(agentB.uuidString)",
            ]
        )
        for binding in derived {
            #expect(binding.outboundMode == .confirm)
            #expect(binding.enabled)
            #expect(binding.isUsable)
            #expect(Set(binding.allowedSources) == Set(AgentChannelBindingRunSource.allCases))
            #expect(binding.connectionId == "discord")
            #expect(AgentChannelAutoDestinationResolver.isAutomaticBindingId(binding.id))
            #expect(binding.displayLabel.contains("Discord"))
        }
    }

    @Test
    func unscopedRouteAgentAnswersEveryWritableRoom() {
        let source = makeSource(
            writableRoomIds: ["room-1", "room-2"],
            defaultAgent: nil,
            routes: [AgentChannelDispatchRoute(roomId: nil, agentId: agentB)]
        )
        let derived = AgentChannelAutoDestinationResolver.derivedBindings(
            sources: [source],
            storedBindings: []
        )
        #expect(derived.count == 2)
        #expect(derived.allSatisfy { $0.agentId == agentB })
        #expect(Set(derived.map(\.roomId)) == ["room-1", "room-2"])
    }

    @Test
    func noDerivationWithoutCredentialWriteAccessOrDispatch() {
        let gatedOff: [AgentChannelAutoDestinationSource] = [
            makeSource(hasCredential: false),
            makeSource(writeEnabled: false),
            makeSource(dispatchEnabled: false),
            makeSource(writableRoomIds: []),
            makeSource(defaultAgent: nil, routes: []),
        ]
        for source in gatedOff {
            let derived = AgentChannelAutoDestinationResolver.derivedBindings(
                sources: [source],
                storedBindings: []
            )
            #expect(derived.isEmpty)
        }
    }

    @Test
    func storedBindingForSameRouteSuppressesDerived() {
        let source = makeSource(writableRoomIds: ["room-1", "room-2"])
        // Customization — including "off" — always wins over derivation.
        let stored = makeStoredBinding(roomId: "room-1", outboundMode: .off)
        let derived = AgentChannelAutoDestinationResolver.derivedBindings(
            sources: [source],
            storedBindings: [stored]
        )
        #expect(derived.count == 1)
        #expect(derived[0].roomId == "room-2")

        let effective = AgentChannelAutoDestinationResolver.effectiveConfiguration(
            stored: AgentChannelConfiguration(bindings: [stored]),
            sources: [source]
        )
        #expect(effective.bindings.count == 2)
        // No usable route for room-1: the stored "off" customization is the
        // only binding for it.
        let usable = effective.usableBindings(agentId: agentA)
        #expect(usable.map(\.roomId) == ["room-2"])
    }

    @Test
    func storedBindingForDifferentAgentDoesNotSuppressOtherAgents() {
        let source = makeSource(
            writableRoomIds: ["room-1"],
            defaultAgent: agentA,
            routes: [AgentChannelDispatchRoute(roomId: "room-1", agentId: agentB)]
        )
        let stored = makeStoredBinding(agentId: agentA, roomId: "room-1")
        let derived = AgentChannelAutoDestinationResolver.derivedBindings(
            sources: [source],
            storedBindings: [stored]
        )
        #expect(derived.count == 1)
        #expect(derived[0].agentId == agentB)
    }

    @Test
    func derivedBindingsAreNeverAutonomous() {
        let sources = [
            makeSource(writableRoomIds: ["room-1", "room-2", "room-3"]),
            makeSource(
                connectionId: "slack",
                displayName: "Slack",
                writableRoomIds: ["C111", "C222"],
                defaultAgent: agentB
            ),
        ]
        let derived = AgentChannelAutoDestinationResolver.derivedBindings(
            sources: sources,
            storedBindings: []
        )
        #expect(!derived.isEmpty)
        #expect(derived.allSatisfy { $0.outboundMode == .confirm })
    }

    @Test
    func automaticIdsAreStableAndDistinctPerAgent() {
        let idA = AgentChannelAutoDestinationResolver.automaticBindingId(
            connectionId: "discord",
            roomId: "room-1",
            agentId: agentA
        )
        let idAAgain = AgentChannelAutoDestinationResolver.automaticBindingId(
            connectionId: "discord",
            roomId: "room-1",
            agentId: agentA
        )
        let idB = AgentChannelAutoDestinationResolver.automaticBindingId(
            connectionId: "discord",
            roomId: "room-1",
            agentId: agentB
        )
        #expect(idA == idAAgain)
        #expect(idA != idB)
        #expect(idA.hasPrefix("auto-discord-room-1-"))
        #expect(AgentChannelAutoDestinationResolver.isAutomaticBindingId(idA))
        #expect(!AgentChannelAutoDestinationResolver.isAutomaticBindingId("daily-report"))
    }

    @Test
    func imessageSourceDerivesOnlyWithVerifiedHelperCredential() {
        // iMessage has no bot token: the verified local helper plays the
        // credential role in the source projection. Without it, no automatic
        // destination may appear even with writable chats and a dispatch
        // agent configured.
        let chat = "iMessage;-;+15551234567"
        let helperMissing = makeSource(
            connectionId: "imessage",
            displayName: "iMessage",
            hasCredential: false,
            writableRoomIds: [chat]
        )
        #expect(
            AgentChannelAutoDestinationResolver.derivedBindings(
                sources: [helperMissing],
                storedBindings: []
            ).isEmpty
        )

        let helperVerified = makeSource(
            connectionId: "imessage",
            displayName: "iMessage",
            hasCredential: true,
            writableRoomIds: [chat]
        )
        let derived = AgentChannelAutoDestinationResolver.derivedBindings(
            sources: [helperVerified],
            storedBindings: []
        )
        #expect(derived.count == 1)
        #expect(derived[0].connectionId == "imessage")
        #expect(derived[0].roomId == chat)
        #expect(derived[0].outboundMode == .confirm)
        #expect(AgentChannelAutoDestinationResolver.isAutomaticBindingId(derived[0].id))
    }

    @Test
    func storedBindingReusingAutomaticIdWinsWithoutDuplicates() {
        let source = makeSource(writableRoomIds: ["room-1"])
        let autoId = AgentChannelAutoDestinationResolver.automaticBindingId(
            connectionId: "discord",
            roomId: "room-1",
            agentId: agentA
        )
        // A materialized customization keeps the automatic id (the inline
        // mode menu does exactly this); the id must stay unique.
        let stored = makeStoredBinding(id: autoId, roomId: "room-1", outboundMode: .autonomous)
        let effective = AgentChannelAutoDestinationResolver.effectiveConfiguration(
            stored: AgentChannelConfiguration(bindings: [stored]),
            sources: [source]
        )
        #expect(effective.bindings.count == 1)
        #expect(effective.binding(id: autoId)?.outboundMode == .autonomous)
    }

    @Test
    func derivedDestinationAppearsInPromptSection() {
        let source = makeSource(writableRoomIds: ["room-1"])
        let effective = AgentChannelAutoDestinationResolver.effectiveConfiguration(
            stored: AgentChannelConfiguration(),
            sources: [source]
        )
        let section = SystemPromptComposer.channelDestinationsSection(
            bindings: effective.usableBindings(agentId: agentA),
            source: .chat
        )
        let autoId = AgentChannelAutoDestinationResolver.automaticBindingId(
            connectionId: "discord",
            roomId: "room-1",
            agentId: agentA
        )
        #expect(section?.contains(autoId) == true)
        // Another agent sees nothing.
        let other = SystemPromptComposer.channelDestinationsSection(
            bindings: effective.usableBindings(agentId: agentB),
            source: .chat
        )
        #expect(other == nil)
    }

    /// Warm-up staleness pin: an outbound-mode edit rewrites the
    /// destinations section BYTES (it is a dynamic section, invisible to the
    /// static-prefix hash), so the warm-up fingerprint — which folds the
    /// full rendered prompt — must change with it. If the two renders below
    /// ever become byte-identical, mode edits would silently stop
    /// invalidating warmed prefixes and every send after such an edit would
    /// cold-re-prefill against a stale warm claim.
    @Test
    func outboundModeEditRewritesDestinationsSectionBytes() {
        let confirmSection = SystemPromptComposer.channelDestinationsSection(
            bindings: [makeStoredBinding(outboundMode: .confirm)],
            source: .chat
        )
        let autonomousSection = SystemPromptComposer.channelDestinationsSection(
            bindings: [makeStoredBinding(outboundMode: .autonomous)],
            source: .chat
        )
        #expect(confirmSection != nil)
        #expect(autonomousSection != nil)
        #expect(confirmSection != autonomousSection)
        // Identical inputs stay byte-identical — the invalidation signal
        // must never fire for a no-op recompose.
        let repeated = SystemPromptComposer.channelDestinationsSection(
            bindings: [makeStoredBinding(outboundMode: .confirm)],
            source: .chat
        )
        #expect(repeated == confirmSection)
    }
}

// MARK: - End-to-end publish with automatic ids

/// Publish-service harness whose configuration is ALWAYS the effective view
/// (stored + derived from mutable sources), mirroring production wiring.
private final class AutoDestinationHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var _sources: [AgentChannelAutoDestinationSource]
    private var _stored: AgentChannelConfiguration
    private var _sendCount = 0

    let store: AgentChannelMessageStore

    init(
        sources: [AgentChannelAutoDestinationSource],
        stored: AgentChannelConfiguration = AgentChannelConfiguration()
    ) throws {
        _sources = sources
        _stored = stored
        store = AgentChannelMessageStore()
        try store.openInMemory()
    }

    var sources: [AgentChannelAutoDestinationSource] {
        get { lock.withLock { _sources } }
        set { lock.withLock { _sources = newValue } }
    }
    var sendCount: Int { lock.withLock { _sendCount } }

    func makeService() -> AgentChannelPublishService {
        AgentChannelPublishService(
            loadConfiguration: { [self] in
                let (sources, stored) = lock.withLock { (_sources, _stored) }
                return AgentChannelAutoDestinationResolver.effectiveConfiguration(
                    stored: stored,
                    sources: sources
                )
            },
            resolveConnection: { id in
                AgentChannelConnection(
                    id: AgentChannelConnection.normalizedId(id),
                    name: "Discord",
                    kind: .customHTTP,
                    enabled: true,
                    supportedActions: AgentChannelAction.allCases,
                    writeRoomAllowlist: ["room-1", "room-2"],
                    writeEnabled: true
                )
            },
            killSwitchSnapshot: { ChannelWriteKillSwitchSnapshot(writeEnabled: true) },
            sender: { [self] _, _ in
                lock.withLock {
                    _sendCount += 1
                    return "provider-msg-\(_sendCount)"
                }
            },
            store: store,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
    }
}

@Suite("AgentChannelAutoDestinationPublish")
struct AgentChannelAutoDestinationPublishTests {

    private var autoId: String {
        AgentChannelAutoDestinationResolver.automaticBindingId(
            connectionId: "discord",
            roomId: "room-1",
            agentId: agentA
        )
    }

    private func context(
        source: SessionSource,
        isUnattendedDispatch: Bool
    ) -> AgentChannelPublishContext {
        AgentChannelPublishContext(
            agentId: agentA,
            source: source,
            isExternalSurface: false,
            isUnattendedDispatch: isUnattendedDispatch,
            sessionId: "session-1"
        )
    }

    @Test
    func attendedChatPublishWithAutomaticIdSends() async throws {
        let harness = try AutoDestinationHarness(sources: [makeSource()])
        let service = harness.makeService()
        let outcome = await service.publish(
            AgentChannelPublishRequest(bindingId: autoId, content: "hello", intentKey: "k1"),
            context: context(source: .chat, isUnattendedDispatch: false)
        )
        guard case .sent = outcome else {
            Issue.record("expected sent, got \(outcome)")
            return
        }
        #expect(harness.sendCount == 1)
    }

    @Test
    func unattendedPublishWithAutomaticIdQueuesThenApproves() async throws {
        let harness = try AutoDestinationHarness(sources: [makeSource()])
        let service = harness.makeService()
        let outcome = await service.publish(
            AgentChannelPublishRequest(bindingId: autoId, content: "hello", intentKey: "k1"),
            context: context(source: .schedule, isUnattendedDispatch: true)
        )
        guard case .queuedForApproval(let intentId) = outcome else {
            Issue.record("expected queuedForApproval, got \(outcome)")
            return
        }
        #expect(harness.sendCount == 0)

        let approved = await service.approvePendingIntent(id: intentId)
        guard case .sent = approved else {
            Issue.record("expected sent after approval, got \(approved)")
            return
        }
        #expect(harness.sendCount == 1)
    }

    @Test
    func queuedApprovalRefusedAfterRoomLeavesAllowlist() async throws {
        let harness = try AutoDestinationHarness(sources: [makeSource()])
        let service = harness.makeService()
        let outcome = await service.publish(
            AgentChannelPublishRequest(bindingId: autoId, content: "hello", intentKey: "k1"),
            context: context(source: .schedule, isUnattendedDispatch: true)
        )
        guard case .queuedForApproval(let intentId) = outcome else {
            Issue.record("expected queuedForApproval, got \(outcome)")
            return
        }

        // Operator removes the room from the channel's write allowlist: the
        // derived binding vanishes and the queued approval must refuse.
        harness.sources = [makeSource(writableRoomIds: [])]
        let refused = await service.approvePendingIntent(id: intentId)
        guard case .denied(let code, _, let retryable) = refused else {
            Issue.record("expected denied, got \(refused)")
            return
        }
        #expect(code == "binding_removed")
        #expect(retryable == false)
        #expect(harness.sendCount == 0)
    }

    @Test
    func unknownAutomaticIdIsRefused() async throws {
        let harness = try AutoDestinationHarness(sources: [makeSource()])
        let service = harness.makeService()
        let bogusId = AgentChannelAutoDestinationResolver.automaticBindingId(
            connectionId: "discord",
            roomId: "room-9",
            agentId: agentA
        )
        let outcome = await service.publish(
            AgentChannelPublishRequest(bindingId: bogusId, content: "hello", intentKey: "k1"),
            context: context(source: .chat, isUnattendedDispatch: false)
        )
        guard case .denied(let code, _, _) = outcome else {
            Issue.record("expected denied, got \(outcome)")
            return
        }
        #expect(code == "binding_not_found")
    }
}
