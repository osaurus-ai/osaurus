//
//  AgentChannelProactivePublishTests.swift
//  OsaurusCoreTests
//
//  Focused coverage for proactive agent channel publishing: binding schema
//  migration/normalization, run-source mapping, redacted prompt composition,
//  the publish authorization matrix, durable idempotency, rate limits,
//  stale-approval rejection, and strictest-wins permission composition.
//

import Foundation
import Testing
@testable import OsaurusCore

// MARK: - Shared fixtures

private let agentA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
private let agentB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

private func makeBinding(
    id: String = "daily-report",
    agentId: UUID = agentA,
    connectionId: String = "discord",
    roomId: String = "room-1",
    threadId: String? = nil,
    guidance: String = "Post the daily summary.",
    allowedSources: [AgentChannelBindingRunSource] = [.chat, .schedule],
    outboundMode: AgentChannelBindingOutboundMode = .autonomous,
    ratePolicy: AgentChannelBindingRatePolicy = AgentChannelBindingRatePolicy(),
    enabled: Bool = true
) -> AgentChannelBinding {
    AgentChannelBinding(
        id: id,
        agentId: agentId,
        connectionId: connectionId,
        roomId: roomId,
        threadId: threadId,
        label: "Daily report",
        guidance: guidance,
        allowedSources: allowedSources,
        outboundMode: outboundMode,
        ratePolicy: ratePolicy,
        enabled: enabled
    )
}

private func makeConnection(
    id: String = "discord",
    enabled: Bool = true,
    writeEnabled: Bool = true,
    writeRoomAllowlist: [String] = ["room-1"],
    supportedActions: [AgentChannelAction] = AgentChannelAction.allCases
) -> AgentChannelConnection {
    AgentChannelConnection(
        id: id,
        name: "Test",
        kind: .customHTTP,
        enabled: enabled,
        supportedActions: supportedActions,
        writeRoomAllowlist: writeRoomAllowlist,
        writeEnabled: writeEnabled
    )
}

private func makeContext(
    agentId: UUID? = agentA,
    source: SessionSource? = .chat,
    isExternalSurface: Bool = false,
    isUnattendedDispatch: Bool = false
) -> AgentChannelPublishContext {
    AgentChannelPublishContext(
        agentId: agentId,
        source: source,
        isExternalSurface: isExternalSurface,
        isUnattendedDispatch: isUnattendedDispatch,
        sessionId: "session-1"
    )
}

/// Mutable test state shared with the service's injected closures.
private final class PublishHarness: @unchecked Sendable {
    private let lock = NSLock()

    private var _configuration: AgentChannelConfiguration
    private var _connection: AgentChannelConnection
    private var _killSwitch = ChannelWriteKillSwitchSnapshot(writeEnabled: true)
    private var _now = Date(timeIntervalSince1970: 1_000_000)
    private var _sendCount = 0
    private var _senderError: Error?
    private var _lastSentContent: String?

    let store: AgentChannelMessageStore

    init(
        bindings: [AgentChannelBinding],
        connection: AgentChannelConnection = makeConnection()
    ) throws {
        _configuration = AgentChannelConfiguration(bindings: bindings)
        _connection = connection
        store = AgentChannelMessageStore()
        try store.openInMemory()
    }

    var configuration: AgentChannelConfiguration {
        get { lock.withLock { _configuration } }
        set { lock.withLock { _configuration = newValue } }
    }
    var connection: AgentChannelConnection {
        get { lock.withLock { _connection } }
        set { lock.withLock { _connection = newValue } }
    }
    var killSwitch: ChannelWriteKillSwitchSnapshot {
        get { lock.withLock { _killSwitch } }
        set { lock.withLock { _killSwitch = newValue } }
    }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    var sendCount: Int { lock.withLock { _sendCount } }
    var senderError: Error? {
        get { lock.withLock { _senderError } }
        set { lock.withLock { _senderError = newValue } }
    }
    var lastSentContent: String? { lock.withLock { _lastSentContent } }

    func makeService() -> AgentChannelPublishService {
        AgentChannelPublishService(
            loadConfiguration: { [self] in configuration },
            resolveConnection: { [self] id in
                let connection = self.connection
                guard connection.id == AgentChannelConnection.normalizedId(id) else {
                    throw AgentChannelConnectionServiceError.connectionNotFound(id)
                }
                return connection
            },
            killSwitchSnapshot: { [self] in killSwitch },
            sender: { [self] _, content in
                if let error = senderError { throw error }
                lock.withLock {
                    _sendCount += 1
                    _lastSentContent = content
                }
                return "provider-msg-\(sendCount)"
            },
            store: store,
            now: { [self] in now }
        )
    }
}

extension AgentChannelPublishOutcome {
    fileprivate var deniedCode: String? {
        if case .denied(let code, _, _) = self { return code }
        return nil
    }
    fileprivate var deniedRetryable: Bool? {
        if case .denied(_, _, let retryable) = self { return retryable }
        return nil
    }
    fileprivate var isSent: Bool {
        if case .sent = self { return true }
        return false
    }
}

// MARK: - Configuration schema & normalization

@Suite("Agent Channel binding configuration")
struct AgentChannelBindingConfigurationTests {
    @Test func v1ConfigurationDecodesWithEmptyBindings() throws {
        let json = """
            {"schemaVersion": 1, "connections": []}
            """
        let decoded = try JSONDecoder().decode(
            AgentChannelConfiguration.self,
            from: Data(json.utf8)
        )
        #expect(decoded.bindings.isEmpty)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.normalized.schemaVersion == AgentChannelConfiguration.currentSchemaVersion)
    }

    @Test func bindingNormalizationTrimsAndDefaults() {
        let binding = AgentChannelBinding(
            id: "  Daily-Report \n",
            agentId: agentA,
            connectionId: " discord ",
            roomId: " room-1 ",
            threadId: "   ",
            label: String(repeating: "x", count: 200),
            guidance: String(repeating: "g", count: 800),
            allowedSources: [.chat, .chat, .schedule],
            outboundMode: .confirm
        )
        #expect(binding.id == "daily-report")
        #expect(binding.connectionId == "discord")
        #expect(binding.roomId == "room-1")
        #expect(binding.threadId == nil)
        #expect(binding.label.count == AgentChannelBinding.maxLabelLength)
        #expect(binding.guidance.count == AgentChannelBinding.maxGuidanceLength)
        #expect(binding.allowedSources == [.chat, .schedule])
    }

    @Test func emptyAllowedSourcesDefaultsToChat() {
        let binding = makeBinding(allowedSources: [])
        #expect(binding.allowedSources == [.chat])
    }

    @Test func duplicateBindingIdsAreDroppedDuringNormalization() {
        let configuration = AgentChannelConfiguration(
            bindings: [
                makeBinding(id: "dup"),
                makeBinding(id: "DUP", roomId: "other-room"),
                makeBinding(id: "unique"),
            ]
        )
        #expect(configuration.bindings.map(\.id) == ["dup", "unique"])
    }

    @Test func usableBindingsFilterOwnershipEnablementAndMode() {
        let configuration = AgentChannelConfiguration(
            bindings: [
                makeBinding(id: "usable"),
                makeBinding(id: "off-mode", outboundMode: .off),
                makeBinding(id: "disabled", enabled: false),
                makeBinding(id: "other-agent", agentId: agentB),
            ]
        )
        #expect(configuration.usableBindings(agentId: agentA).map(\.id) == ["usable"])
        #expect(configuration.bindings(agentId: agentA).count == 3)
    }

    @Test func runSourceMappingRejectsExternalAndLateralSources() {
        #expect(AgentChannelBindingRunSource(sessionSource: .chat) == .chat)
        #expect(AgentChannelBindingRunSource(sessionSource: .schedule) == .schedule)
        #expect(AgentChannelBindingRunSource(sessionSource: .watcher) == .watcher)
        #expect(AgentChannelBindingRunSource(sessionSource: .selfSchedule) == .selfSchedule)
        #expect(AgentChannelBindingRunSource(sessionSource: .plugin) == nil)
        #expect(AgentChannelBindingRunSource(sessionSource: .http) == nil)
        #expect(AgentChannelBindingRunSource(sessionSource: .channel) == nil)
    }
}

// MARK: - Prompt composition

@Suite("Channel destinations prompt section")
struct ChannelDestinationsPromptTests {
    @Test func nilOrExternalSourceProducesNoSection() {
        let bindings = [makeBinding()]
        #expect(SystemPromptComposer.channelDestinationsSection(bindings: bindings, source: nil) == nil)
        #expect(
            SystemPromptComposer.channelDestinationsSection(bindings: bindings, source: .plugin) == nil
        )
        #expect(
            SystemPromptComposer.channelDestinationsSection(bindings: bindings, source: .channel) == nil
        )
    }

    @Test func sectionListsOnlyBindingsAllowingTheRunSource() throws {
        let bindings = [
            makeBinding(id: "chat-only", allowedSources: [.chat]),
            makeBinding(id: "schedule-only", allowedSources: [.schedule]),
            makeBinding(id: "off-mode", outboundMode: .off),
            makeBinding(id: "disabled", enabled: false),
        ]
        let section = try #require(
            SystemPromptComposer.channelDestinationsSection(bindings: bindings, source: .chat)
        )
        #expect(section.contains("`chat-only`"))
        #expect(!section.contains("schedule-only"))
        #expect(!section.contains("off-mode"))
        #expect(!section.contains("`disabled`"))
        #expect(section.contains("agent_channel_publish"))
        #expect(section.contains("intent_key"))
        #expect(section.contains("When to use: Post the daily summary."))
    }

    @Test func noUsableBindingsProducesNoSection() {
        let bindings = [makeBinding(id: "schedule-only", allowedSources: [.schedule])]
        #expect(
            SystemPromptComposer.channelDestinationsSection(bindings: bindings, source: .chat) == nil
        )
    }
}

// MARK: - Publish authorization matrix

@Suite("Agent Channel publish service")
struct AgentChannelPublishServiceTests {
    private func request(
        bindingId: String = "daily-report",
        content: String = "hello world",
        intentKey: String = "key-1"
    ) -> AgentChannelPublishRequest {
        AgentChannelPublishRequest(bindingId: bindingId, content: content, intentKey: intentKey)
    }

    @Test func externalSurfaceIsAlwaysDenied() async throws {
        let harness = try PublishHarness(bindings: [makeBinding()])
        defer { harness.store.close() }
        let outcome = await harness.makeService().publish(
            request(),
            context: makeContext(isExternalSurface: true)
        )
        #expect(outcome.deniedCode == "external_surface_denied")
        #expect(harness.sendCount == 0)
    }

    @Test func missingAgentIdentityIsDenied() async throws {
        let harness = try PublishHarness(bindings: [makeBinding()])
        defer { harness.store.close() }
        let outcome = await harness.makeService().publish(
            request(),
            context: makeContext(agentId: nil)
        )
        #expect(outcome.deniedCode == "missing_agent_context")
    }

    @Test func lateralAndExternalRunSourcesAreDenied() async throws {
        let harness = try PublishHarness(bindings: [makeBinding()])
        defer { harness.store.close() }
        let service = harness.makeService()
        for source in [SessionSource.plugin, .http, .channel] {
            let outcome = await service.publish(request(), context: makeContext(source: source))
            #expect(outcome.deniedCode == "run_source_not_allowed")
        }
        let missing = await service.publish(request(), context: makeContext(source: nil))
        #expect(missing.deniedCode == "run_source_not_allowed")
        #expect(harness.sendCount == 0)
    }

    @Test func bindingOwnershipModeAndSourceAreEnforced() async throws {
        let harness = try PublishHarness(
            bindings: [
                makeBinding(id: "not-owned", agentId: agentB),
                makeBinding(id: "disabled", enabled: false),
                makeBinding(id: "mode-off", outboundMode: .off),
                makeBinding(id: "schedule-only", allowedSources: [.schedule]),
            ]
        )
        defer { harness.store.close() }
        let service = harness.makeService()

        let notFound = await service.publish(
            request(bindingId: "ghost"),
            context: makeContext()
        )
        #expect(notFound.deniedCode == "binding_not_found")

        let notOwned = await service.publish(
            request(bindingId: "not-owned"),
            context: makeContext()
        )
        #expect(notOwned.deniedCode == "binding_not_owned")

        let disabled = await service.publish(
            request(bindingId: "disabled"),
            context: makeContext()
        )
        #expect(disabled.deniedCode == "binding_disabled")

        let modeOff = await service.publish(
            request(bindingId: "mode-off"),
            context: makeContext()
        )
        #expect(modeOff.deniedCode == "binding_mode_off")

        let wrongSource = await service.publish(
            request(bindingId: "schedule-only"),
            context: makeContext(source: .chat)
        )
        #expect(wrongSource.deniedCode == "run_source_not_allowed")
        #expect(harness.sendCount == 0)
    }

    @Test func draftModeRecordsDraftWithoutProviderIO() async throws {
        let harness = try PublishHarness(bindings: [makeBinding(outboundMode: .draft)])
        defer { harness.store.close() }
        let outcome = await harness.makeService().publish(request(), context: makeContext())
        guard case .draftRecorded(let intentId) = outcome else {
            Issue.record("expected draftRecorded, got \(outcome)")
            return
        }
        #expect(harness.sendCount == 0)
        let intent = try #require(try harness.store.outboundIntent(id: intentId))
        #expect(intent.status == .draft)
        #expect(intent.content == "hello world")
    }

    @Test func confirmModeQueuesOnUnattendedRuns() async throws {
        let harness = try PublishHarness(bindings: [makeBinding(outboundMode: .confirm)])
        defer { harness.store.close() }
        let outcome = await harness.makeService().publish(
            request(),
            context: makeContext(source: .schedule, isUnattendedDispatch: true)
        )
        guard case .queuedForApproval(let intentId) = outcome else {
            Issue.record("expected queuedForApproval, got \(outcome)")
            return
        }
        #expect(harness.sendCount == 0)
        let intent = try #require(try harness.store.outboundIntent(id: intentId))
        #expect(intent.status == .pending)
    }

    @Test func confirmModeSendsOnAttendedRuns() async throws {
        let harness = try PublishHarness(bindings: [makeBinding(outboundMode: .confirm)])
        defer { harness.store.close() }
        let outcome = await harness.makeService().publish(request(), context: makeContext())
        #expect(outcome.isSent)
        #expect(harness.sendCount == 1)
    }

    @Test func autonomousModeSendsAndRecordsProviderMessageId() async throws {
        let harness = try PublishHarness(bindings: [makeBinding()])
        defer { harness.store.close() }
        let outcome = await harness.makeService().publish(request(), context: makeContext())
        guard case .sent(let intentId, let providerMessageId) = outcome else {
            Issue.record("expected sent, got \(outcome)")
            return
        }
        #expect(providerMessageId == "provider-msg-1")
        #expect(harness.lastSentContent == "hello world")
        let intent = try #require(try harness.store.outboundIntent(id: intentId))
        #expect(intent.status == .sent)
        #expect(intent.providerMessageId == "provider-msg-1")
    }

    @Test func killSwitchBlocksAutonomousSends() async throws {
        let harness = try PublishHarness(bindings: [makeBinding()])
        defer { harness.store.close() }
        harness.killSwitch = ChannelWriteKillSwitchSnapshot(writeEnabled: false, generation: 3)
        let outcome = await harness.makeService().publish(request(), context: makeContext())
        #expect(outcome.deniedCode == "global_writes_disabled")
        #expect(harness.sendCount == 0)
    }

    @Test func connectionWriteGatesAndAllowlistAreEnforced() async throws {
        let harness = try PublishHarness(bindings: [makeBinding()])
        defer { harness.store.close() }
        let service = harness.makeService()

        harness.connection = makeConnection(writeEnabled: false)
        let writesOff = await service.publish(request(), context: makeContext())
        #expect(writesOff.deniedCode == "connection_writes_disabled")

        harness.connection = makeConnection(writeRoomAllowlist: ["another-room"])
        let notAllowlisted = await service.publish(request(), context: makeContext())
        #expect(notAllowlisted.deniedCode == "room_not_write_allowlisted")

        harness.connection = makeConnection(enabled: false)
        let disabled = await service.publish(request(), context: makeContext())
        #expect(disabled.deniedCode == "connection_disabled")
        #expect(harness.sendCount == 0)
    }

    @Test func repeatedIntentKeyNeverSendsTwice() async throws {
        let harness = try PublishHarness(bindings: [makeBinding()])
        defer { harness.store.close() }
        let service = harness.makeService()

        let first = await service.publish(request(intentKey: "once"), context: makeContext())
        #expect(first.isSent)

        let replay = await service.publish(request(intentKey: "once"), context: makeContext())
        guard case .duplicate(_, let status) = replay else {
            Issue.record("expected duplicate, got \(replay)")
            return
        }
        #expect(status == .sent)
        #expect(harness.sendCount == 1)
    }

    @Test func hourlyRateLimitIsEnforcedAgainstLedger() async throws {
        let harness = try PublishHarness(
            bindings: [
                makeBinding(
                    ratePolicy: AgentChannelBindingRatePolicy(
                        maxSendsPerHour: 1,
                        minSecondsBetweenSends: 0
                    )
                )
            ]
        )
        defer { harness.store.close() }
        let service = harness.makeService()

        let first = await service.publish(request(intentKey: "a"), context: makeContext())
        #expect(first.isSent)

        let second = await service.publish(request(intentKey: "b"), context: makeContext())
        #expect(second.deniedCode == "rate_limited")
        #expect(second.deniedRetryable == true)

        // Past the hour window the binding may send again.
        harness.now = harness.now.addingTimeInterval(3_601)
        let third = await service.publish(request(intentKey: "c"), context: makeContext())
        #expect(third.isSent)
        #expect(harness.sendCount == 2)
    }

    @Test func minimumGapBetweenSendsIsEnforced() async throws {
        let harness = try PublishHarness(
            bindings: [
                makeBinding(
                    ratePolicy: AgentChannelBindingRatePolicy(
                        maxSendsPerHour: 100,
                        minSecondsBetweenSends: 30
                    )
                )
            ]
        )
        defer { harness.store.close() }
        let service = harness.makeService()

        let first = await service.publish(request(intentKey: "a"), context: makeContext())
        #expect(first.isSent)

        harness.now = harness.now.addingTimeInterval(5)
        let tooSoon = await service.publish(request(intentKey: "b"), context: makeContext())
        #expect(tooSoon.deniedCode == "rate_limited")

        harness.now = harness.now.addingTimeInterval(31)
        let later = await service.publish(request(intentKey: "c"), context: makeContext())
        #expect(later.isSent)
    }

    @Test func providerFailureIsRetryableWithoutDuplicateSend() async throws {
        let harness = try PublishHarness(bindings: [makeBinding()])
        defer { harness.store.close() }
        let service = harness.makeService()

        // A connection-refused failure is DETERMINISTIC (the request body
        // never reached the provider), so the intent parks as retryable
        // `failed` — ambiguous failures are covered by the hardening suite.
        harness.senderError = URLError(.cannotConnectToHost)
        let failed = await service.publish(request(intentKey: "retry-me"), context: makeContext())
        #expect(failed.deniedCode == "provider_error")
        #expect(failed.deniedRetryable == true)

        // Retrying the SAME intent key after the failure performs exactly one
        // provider write.
        harness.senderError = nil
        let retried = await service.publish(request(intentKey: "retry-me"), context: makeContext())
        #expect(retried.isSent)
        #expect(harness.sendCount == 1)
    }

    @Test func approvalReRunsPolicyAgainstCurrentSettings() async throws {
        let harness = try PublishHarness(bindings: [makeBinding(outboundMode: .confirm)])
        defer { harness.store.close() }
        let service = harness.makeService()

        let queued = await service.publish(
            request(),
            context: makeContext(source: .schedule, isUnattendedDispatch: true)
        )
        guard case .queuedForApproval(let intentId) = queued else {
            Issue.record("expected queuedForApproval, got \(queued)")
            return
        }

        // The operator turned the binding off after the item was queued:
        // approval must refuse and mark the item failed instead of sending.
        harness.configuration = AgentChannelConfiguration(
            bindings: [makeBinding(outboundMode: .off)]
        )
        let stale = await service.approvePendingIntent(id: intentId)
        #expect(stale.deniedCode == "binding_policy_changed")
        #expect(harness.sendCount == 0)
        let intent = try #require(try harness.store.outboundIntent(id: intentId))
        #expect(intent.status == .failed)
    }

    @Test func approvalSendsWhenPolicyStillAllows() async throws {
        let harness = try PublishHarness(bindings: [makeBinding(outboundMode: .confirm)])
        defer { harness.store.close() }
        let service = harness.makeService()

        let queued = await service.publish(
            request(),
            context: makeContext(source: .schedule, isUnattendedDispatch: true)
        )
        guard case .queuedForApproval(let intentId) = queued else {
            Issue.record("expected queuedForApproval, got \(queued)")
            return
        }
        let approved = await service.approvePendingIntent(id: intentId)
        #expect(approved.isSent)
        #expect(harness.sendCount == 1)

        // A second approval of the same item must not send again.
        let again = await service.approvePendingIntent(id: intentId)
        #expect(again.deniedCode == "intent_not_actionable")
        #expect(harness.sendCount == 1)
    }

    @Test func discardCancelsPendingAndDraftIntents() async throws {
        let harness = try PublishHarness(
            bindings: [
                makeBinding(id: "confirm-binding", outboundMode: .confirm),
                makeBinding(id: "draft-binding", outboundMode: .draft),
            ]
        )
        defer { harness.store.close() }
        let service = harness.makeService()

        let queued = await service.publish(
            request(bindingId: "confirm-binding"),
            context: makeContext(source: .schedule, isUnattendedDispatch: true)
        )
        guard case .queuedForApproval(let pendingId) = queued else {
            Issue.record("expected queuedForApproval, got \(queued)")
            return
        }
        let draft = await service.publish(
            request(bindingId: "draft-binding", intentKey: "key-2"),
            context: makeContext()
        )
        guard case .draftRecorded(let draftId) = draft else {
            Issue.record("expected draftRecorded, got \(draft)")
            return
        }

        #expect(await service.discardIntent(id: pendingId))
        #expect(await service.discardIntent(id: draftId))
        let pendingIntent = try #require(try harness.store.outboundIntent(id: pendingId))
        let draftIntent = try #require(try harness.store.outboundIntent(id: draftId))
        #expect(pendingIntent.status == .cancelled)
        #expect(draftIntent.status == .cancelled)
        // A cancelled item can no longer be approved.
        let cancelled = await service.approvePendingIntent(id: pendingId)
        #expect(cancelled.deniedCode == "intent_not_actionable")
    }

    @Test func publishDenialsAreAudited() async throws {
        let harness = try PublishHarness(bindings: [makeBinding(outboundMode: .off)])
        defer { harness.store.close() }
        _ = await harness.makeService().publish(request(), context: makeContext())
        let events = try harness.store.recentAuditEvents(limit: 10)
        #expect(
            events.contains {
                $0.action == AgentChannelPublishService.auditAction && $0.status == .denied
                    && $0.reason == "binding_mode_off"
            }
        )
    }

    @Test func providerMessageIdExtractionHandlesProviderShapes() {
        #expect(
            AgentChannelPublishService.extractProviderMessageId(["message_id": "42"]) == "42"
        )
        #expect(
            AgentChannelPublishService.extractProviderMessageId(
                ["message": ["id": "discord-1"]]
            ) == "discord-1"
        )
        #expect(
            AgentChannelPublishService.extractProviderMessageId(
                ["message": ["ts": "1712.0012"]]
            ) == "1712.0012"
        )
        #expect(
            AgentChannelPublishService.extractProviderMessageId(
                ["message": ["message_id": NSNumber(value: 77)]]
            ) == "77"
        )
        #expect(AgentChannelPublishService.extractProviderMessageId(["ok": true]) == nil)
    }
}

// MARK: - Durable ledger primitives

@Suite("Outbound intent ledger")
struct AgentChannelOutboundIntentLedgerTests {
    @Test func statusTransitionIsCompareAndSet() throws {
        let store = AgentChannelMessageStore()
        try store.openInMemory()
        defer { store.close() }

        let intent = AgentChannelOutboundIntent(
            agentId: agentA,
            bindingId: "b",
            connectionId: "c",
            roomId: "r",
            intentKey: "k",
            content: "hi",
            status: .sending
        )
        let claim = try store.upsertOutboundIntentIfNew(intent)
        #expect(claim.inserted)

        // Wrong expected status loses the CAS.
        #expect(try store.transitionOutboundIntent(id: intent.id, from: .pending, to: .sent) == false)
        #expect(try store.transitionOutboundIntent(id: intent.id, from: .sending, to: .sent))
        // Only one caller can win the same transition.
        #expect(try store.transitionOutboundIntent(id: intent.id, from: .sending, to: .sent) == false)
    }

    @Test func upsertReturnsExistingRowOnReplayedKey() throws {
        let store = AgentChannelMessageStore()
        try store.openInMemory()
        defer { store.close() }

        let first = AgentChannelOutboundIntent(
            agentId: agentA,
            bindingId: "b",
            connectionId: "c",
            roomId: "r",
            intentKey: "same-key",
            content: "first",
            status: .sent
        )
        #expect(try store.upsertOutboundIntentIfNew(first).inserted)

        let replay = AgentChannelOutboundIntent(
            agentId: agentA,
            bindingId: "b",
            connectionId: "c",
            roomId: "r",
            intentKey: "same-key",
            content: "second",
            status: .sending
        )
        let claim = try store.upsertOutboundIntentIfNew(replay)
        #expect(!claim.inserted)
        #expect(claim.intent.id == first.id)
        #expect(claim.intent.content == "first")
        #expect(claim.intent.status == .sent)
    }
}

// MARK: - Strictest-wins permission composition

@Suite("Strictest-wins tool permissions")
struct StrictestWinsPermissionTests {
    @Test func strictestCombinatorOrdersDenyOverAskOverAuto() {
        #expect(ToolPermissionPolicy.strictest(.auto, .auto) == .auto)
        #expect(ToolPermissionPolicy.strictest(.auto, .ask) == .ask)
        #expect(ToolPermissionPolicy.strictest(.ask, .auto) == .ask)
        #expect(ToolPermissionPolicy.strictest(.deny, .ask) == .deny)
        #expect(ToolPermissionPolicy.strictest(.auto, .deny) == .deny)
    }

    @Test func confirmBindingResolvesToAskOnlyOnAttendedRuns() async {
        let configuration = AgentChannelConfiguration(
            bindings: [makeBinding(outboundMode: .confirm)]
        )
        let tool = AgentChannelPublishTool(loadConfiguration: { configuration })
        let args = #"{"binding_id":"daily-report","content":"x","intent_key":"k"}"#

        let attended = await tool.resolveContextualPermissionPolicy(argumentsJSON: args)
        #expect(attended == .ask)

        let unattended = await ChatExecutionContext.$isUnattendedDispatch.withValue(true) {
            await tool.resolveContextualPermissionPolicy(argumentsJSON: args)
        }
        #expect(unattended == .auto)

        let unknownBinding = await tool.resolveContextualPermissionPolicy(
            argumentsJSON: #"{"binding_id":"ghost","content":"x","intent_key":"k"}"#
        )
        #expect(unknownBinding == .auto)
    }

    @Test func autonomousAndDraftBindingsResolveToAuto() async {
        let configuration = AgentChannelConfiguration(
            bindings: [
                makeBinding(id: "auto-binding", outboundMode: .autonomous),
                makeBinding(id: "draft-binding", outboundMode: .draft),
            ]
        )
        let tool = AgentChannelPublishTool(loadConfiguration: { configuration })
        for bindingId in ["auto-binding", "draft-binding"] {
            let policy = await tool.resolveContextualPermissionPolicy(
                argumentsJSON: #"{"binding_id":"\#(bindingId)","content":"x","intent_key":"k"}"#
            )
            #expect(policy == .auto)
        }
    }
}
