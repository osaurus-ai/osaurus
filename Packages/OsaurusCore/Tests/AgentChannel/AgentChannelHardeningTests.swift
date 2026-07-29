//
//  AgentChannelHardeningTests.swift
//  OsaurusCoreTests
//
//  Coverage for the proactive-channel hardening pass: ambiguous-failure
//  classification and the `delivery_unknown` state, per-binding send
//  serialization under rate policy, crash reconciliation, retention
//  pruning, the optional thread contract, stale-route / narrowed-source
//  approval refusal, operator draft promotion and unknown-delivery
//  resolution, binding lifecycle safety (referential integrity, cascade
//  disable, agent-delete cleanup, import re-acknowledgement), and the
//  unattended `.ask` queue-for-approval disposition in the tool registry.
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
        guidance: "Post the daily summary.",
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
    writeRoomAllowlist: [String] = ["room-1"]
) -> AgentChannelConnection {
    AgentChannelConnection(
        id: id,
        name: "Test",
        kind: .customHTTP,
        enabled: enabled,
        supportedActions: AgentChannelAction.allCases,
        writeRoomAllowlist: writeRoomAllowlist,
        writeEnabled: writeEnabled
    )
}

private func makeContext(
    agentId: UUID? = agentA,
    source: SessionSource? = .chat,
    isUnattendedDispatch: Bool = false,
    requiresOperatorApproval: Bool = false
) -> AgentChannelPublishContext {
    AgentChannelPublishContext(
        agentId: agentId,
        source: source,
        isExternalSurface: false,
        isUnattendedDispatch: isUnattendedDispatch,
        sessionId: "session-1",
        requiresOperatorApproval: requiresOperatorApproval
    )
}

/// Test double around the publish service's injected closures. The sender
/// is fully swappable per test (throwing, blocking, or recording).
private final class HardeningHarness: @unchecked Sendable {
    private let lock = NSLock()

    private var _configuration: AgentChannelConfiguration
    private var _connection: AgentChannelConnection
    private var _now = Date(timeIntervalSince1970: 1_000_000)
    private var _sendCount = 0
    private var _sender: AgentChannelPublishService.Sender
    private var _lastSentBinding: AgentChannelBinding?

    let store: AgentChannelMessageStore

    init(
        bindings: [AgentChannelBinding],
        connection: AgentChannelConnection = makeConnection()
    ) throws {
        _configuration = AgentChannelConfiguration(bindings: bindings)
        _connection = connection
        _sender = { _, _ in nil }
        store = AgentChannelMessageStore()
        try store.openInMemory()
        _sender = { [weak self] binding, _ in
            guard let self else { return nil }
            return self.lock.withLock {
                self._sendCount += 1
                self._lastSentBinding = binding
                return "provider-msg-\(self._sendCount)"
            }
        }
    }

    var configuration: AgentChannelConfiguration {
        get { lock.withLock { _configuration } }
        set { lock.withLock { _configuration = newValue } }
    }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    var sendCount: Int { lock.withLock { _sendCount } }
    var lastSentBinding: AgentChannelBinding? { lock.withLock { _lastSentBinding } }

    /// Replace the sender with one that throws `error` on every attempt.
    func failSends(with error: Error) {
        lock.withLock { _sender = { _, _ in throw error } }
    }

    /// Restore the default recording sender.
    func succeedSends() {
        lock.withLock {
            _sender = { [weak self] binding, _ in
                guard let self else { return nil }
                return self.lock.withLock {
                    self._sendCount += 1
                    self._lastSentBinding = binding
                    return "provider-msg-\(self._sendCount)"
                }
            }
        }
    }

    /// Replace the sender with one that suspends for `delay` seconds before
    /// recording the send, to widen the actor-reentrancy window.
    func slowSends(delay: TimeInterval) {
        lock.withLock {
            _sender = { [weak self] binding, _ in
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return nil }
                return self.lock.withLock {
                    self._sendCount += 1
                    self._lastSentBinding = binding
                    return "provider-msg-\(self._sendCount)"
                }
            }
        }
    }

    func makeService() -> AgentChannelPublishService {
        AgentChannelPublishService(
            loadConfiguration: { [self] in configuration },
            resolveConnection: { [self] id in
                let connection = lock.withLock { _connection }
                guard connection.id == AgentChannelConnection.normalizedId(id) else {
                    throw AgentChannelConnectionServiceError.connectionNotFound(id)
                }
                return connection
            },
            killSwitchSnapshot: { ChannelWriteKillSwitchSnapshot(writeEnabled: true) },
            sender: { [self] binding, content in
                let sender = lock.withLock { _sender }
                return try await sender(binding, content)
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
    fileprivate var queuedIntentId: String? {
        if case .queuedForApproval(let id) = self { return id }
        return nil
    }
    fileprivate var draftIntentId: String? {
        if case .draftRecorded(let id) = self { return id }
        return nil
    }
}

private func request(
    bindingId: String = "daily-report",
    content: String = "hello world",
    intentKey: String = "key-1",
    threadId: String? = nil
) -> AgentChannelPublishRequest {
    AgentChannelPublishRequest(
        bindingId: bindingId,
        content: content,
        intentKey: intentKey,
        threadId: threadId
    )
}

// MARK: - Failure classification & delivery_unknown

@Suite("Delivery-unknown state machine")
struct AgentChannelDeliveryUnknownTests {
    @Test func failureClassificationSeparatesDeterministicFromAmbiguous() {
        // Rejected before any write could be accepted.
        #expect(
            AgentChannelPublishService.classifyProviderFailure(
                URLError(.cannotConnectToHost)
            ) == .deterministic
        )
        #expect(
            AgentChannelPublishService.classifyProviderFailure(
                AgentChannelConnectionServiceError.connectionNotFound("x")
            ) == .deterministic
        )
        // The request may have gone out: timeout, connection dropped
        // mid-flight, or a completely unrecognized error.
        #expect(
            AgentChannelPublishService.classifyProviderFailure(URLError(.timedOut)) == .ambiguous
        )
        #expect(
            AgentChannelPublishService.classifyProviderFailure(
                URLError(.networkConnectionLost)
            ) == .ambiguous
        )
        struct Mystery: Error {}
        #expect(AgentChannelPublishService.classifyProviderFailure(Mystery()) == .ambiguous)
    }

    @Test func ambiguousFailureParksDeliveryUnknownAndNeverAutoRetries() async throws {
        let harness = try HardeningHarness(bindings: [makeBinding()])
        defer { harness.store.close() }
        let service = harness.makeService()

        harness.failSends(with: URLError(.timedOut))
        let failed = await service.publish(request(intentKey: "maybe-sent"), context: makeContext())
        #expect(failed.deniedCode == "delivery_unknown")
        #expect(failed.deniedRetryable == false)

        let intents = try harness.store.recentOutboundIntents(limit: 10)
        let parked = try #require(intents.first)
        #expect(parked.status == .deliveryUnknown)

        // Replaying the same intent key must NOT resend, even after the
        // provider recovers: only an operator may resolve the row.
        harness.succeedSends()
        let replay = await service.publish(request(intentKey: "maybe-sent"), context: makeContext())
        guard case .duplicate(_, let status) = replay else {
            Issue.record("expected duplicate, got \(replay)")
            return
        }
        #expect(status == .deliveryUnknown)
        #expect(harness.sendCount == 0)
    }

    @Test func operatorResolvesUnknownDeliveryWithoutProviderIO() async throws {
        let harness = try HardeningHarness(bindings: [makeBinding()])
        defer { harness.store.close() }
        let service = harness.makeService()

        harness.failSends(with: URLError(.timedOut))
        _ = await service.publish(request(intentKey: "a"), context: makeContext())
        _ = await service.publish(request(intentKey: "b"), context: makeContext())
        let parked = try harness.store.recentOutboundIntents(
            statuses: [.deliveryUnknown],
            limit: 10
        )
        #expect(parked.count == 2)

        // Mark-sent records the delivery (and it now counts toward the
        // binding's rate ledger); discard cancels it. Neither touches the
        // provider.
        #expect(await service.resolveUnknownDeliveryIntent(id: parked[0].id, markSent: true))
        #expect(await service.resolveUnknownDeliveryIntent(id: parked[1].id, markSent: false))
        #expect(harness.sendCount == 0)

        let first = try #require(try harness.store.outboundIntent(id: parked[0].id))
        let second = try #require(try harness.store.outboundIntent(id: parked[1].id))
        #expect(first.status == .sent)
        #expect(second.status == .cancelled)
        let counted = try harness.store.sentOutboundIntentCount(
            bindingId: "daily-report",
            since: harness.now.addingTimeInterval(-3_600)
        )
        #expect(counted == 1)

        // Resolution is single-shot.
        #expect(await service.resolveUnknownDeliveryIntent(id: parked[0].id, markSent: true) == false)
    }

    @Test func operatorRetryOfUnknownDeliveryPerformsExactlyOneSend() async throws {
        let harness = try HardeningHarness(bindings: [makeBinding()])
        defer { harness.store.close() }
        let service = harness.makeService()

        harness.failSends(with: URLError(.timedOut))
        _ = await service.publish(request(intentKey: "retry-unknown"), context: makeContext())
        let parked = try #require(try harness.store.recentOutboundIntents(limit: 1).first)
        #expect(parked.status == .deliveryUnknown)

        harness.succeedSends()
        let retried = await service.retryUnknownDeliveryIntent(id: parked.id)
        #expect(retried.isSent)
        #expect(harness.sendCount == 1)
        let resolved = try #require(try harness.store.outboundIntent(id: parked.id))
        #expect(resolved.status == .sent)
    }

    @Test func interruptedSendsReconcileToDeliveryUnknownOnStartup() async throws {
        let harness = try HardeningHarness(bindings: [makeBinding()])
        defer { harness.store.close() }

        // A `.sending` row from a previous process run (older than this
        // service instance's start) and a fresh one from "this" run.
        let stale = AgentChannelOutboundIntent(
            agentId: agentA,
            bindingId: "daily-report",
            connectionId: "discord",
            roomId: "room-1",
            intentKey: "crashed",
            content: "was mid-flight",
            status: .sending,
            createdAt: Date(timeIntervalSince1970: 998_000),
            updatedAt: Date(timeIntervalSince1970: 999_000)
        )
        let fresh = AgentChannelOutboundIntent(
            agentId: agentA,
            bindingId: "daily-report",
            connectionId: "discord",
            roomId: "room-1",
            intentKey: "in-flight-now",
            content: "still going",
            status: .sending,
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        #expect(try harness.store.upsertOutboundIntentIfNew(stale).inserted)
        #expect(try harness.store.upsertOutboundIntentIfNew(fresh).inserted)

        // Service startedAt == harness.now == 1_000_000.
        let service = harness.makeService()
        await service.reconcileInterruptedWork()

        let reconciled = try #require(try harness.store.outboundIntent(id: stale.id))
        #expect(reconciled.status == .deliveryUnknown)
        #expect(reconciled.failureCode == "interrupted_send")
        let untouched = try #require(try harness.store.outboundIntent(id: fresh.id))
        #expect(untouched.status == .sending)
    }

    @Test func retentionPrunesTerminalRowsButNeverUnresolvedOnes() throws {
        let store = AgentChannelMessageStore()
        try store.openInMemory()
        defer { store.close() }

        let old = Date(timeIntervalSince1970: 100)
        func insert(_ key: String, _ status: AgentChannelOutboundIntentStatus) throws {
            _ = try store.upsertOutboundIntentIfNew(
                AgentChannelOutboundIntent(
                    agentId: agentA,
                    bindingId: "b",
                    connectionId: "c",
                    roomId: "r",
                    intentKey: key,
                    content: "x",
                    status: status,
                    createdAt: old,
                    updatedAt: old
                )
            )
        }
        try insert("sent", .sent)
        try insert("failed", .failed)
        try insert("cancelled", .cancelled)
        try insert("pending", .pending)
        try insert("draft", .draft)
        try insert("unknown", .deliveryUnknown)

        let pruned = try store.pruneTerminalOutboundIntents(
            olderThan: Date(timeIntervalSince1970: 1_000)
        )
        #expect(pruned == 3)
        let survivors = try store.recentOutboundIntents(limit: 10)
        #expect(Set(survivors.map(\.intentKey)) == ["pending", "draft", "unknown"])
        #expect(try store.outboundIntentCount(status: .pending) == 1)
        #expect(try store.outboundIntentCount(status: .deliveryUnknown) == 1)
        #expect(try store.outboundIntentCount(status: .sent) == 0)
    }

    @Test func unresolvedRowsSurviveBeyondTheLatestHistoryWindow() throws {
        let store = AgentChannelMessageStore()
        try store.openInMemory()
        defer { store.close() }

        // 5 OLD unresolved rows buried under 120 newer terminal rows: a
        // single "latest 100 across all statuses" query would hide them,
        // which is exactly how approvals used to vanish from the outbox.
        for index in 0..<5 {
            _ = try store.upsertOutboundIntentIfNew(
                AgentChannelOutboundIntent(
                    agentId: agentA,
                    bindingId: "b",
                    connectionId: "c",
                    roomId: "r",
                    intentKey: "old-pending-\(index)",
                    content: "x",
                    status: .pending,
                    createdAt: Date(timeIntervalSince1970: 1_000),
                    updatedAt: Date(timeIntervalSince1970: 1_000)
                )
            )
        }
        for index in 0..<120 {
            _ = try store.upsertOutboundIntentIfNew(
                AgentChannelOutboundIntent(
                    agentId: agentA,
                    bindingId: "b",
                    connectionId: "c",
                    roomId: "r",
                    intentKey: "new-sent-\(index)",
                    content: "x",
                    status: .sent,
                    createdAt: Date(timeIntervalSince1970: 2_000 + Double(index)),
                    updatedAt: Date(timeIntervalSince1970: 2_000 + Double(index))
                )
            )
        }

        let blended = try store.recentOutboundIntents(limit: 100)
        #expect(!blended.contains { $0.status == .pending })

        // The status-scoped query the outbox uses for its unresolved panels
        // still returns every buried row.
        let pending = try store.recentOutboundIntents(statuses: [.pending], limit: 100)
        #expect(pending.count == 5)
        #expect(try store.outboundIntentCount(status: .pending) == 5)
    }

    @Test func unresolvedStatusesAreExactlyTheAttentionSet() {
        for status in AgentChannelOutboundIntentStatus.allCases {
            let expected: Bool
            switch status {
            case .draft, .pending, .sending, .deliveryUnknown: expected = true
            case .sent, .failed, .cancelled: expected = false
            }
            #expect(status.isUnresolved == expected, "\(status)")
        }
    }
}

// MARK: - Per-binding serialization

@Suite("Per-binding send serialization")
struct AgentChannelSendSerializationTests {
    @Test func concurrentPublishesCannotDoubleSpendRateHeadroom() async throws {
        let harness = try HardeningHarness(
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

        // The sender suspends, so without the per-binding lock both
        // publishes would pass the rate check before either send is
        // recorded (actors are reentrant across await).
        harness.slowSends(delay: 0.1)
        async let firstAttempt = service.publish(
            request(intentKey: "concurrent-a"),
            context: makeContext()
        )
        async let secondAttempt = service.publish(
            request(intentKey: "concurrent-b"),
            context: makeContext()
        )
        let outcomes = await [firstAttempt, secondAttempt]

        #expect(outcomes.filter(\.isSent).count == 1)
        #expect(outcomes.compactMap(\.deniedCode) == ["rate_limited"])
        #expect(harness.sendCount == 1)
    }
}

// MARK: - Thread contract & input hardening

@Suite("Publish thread contract")
struct AgentChannelThreadContractTests {
    @Test func bindingPinnedThreadRefusesConflictingRequestThread() async throws {
        let harness = try HardeningHarness(bindings: [makeBinding(threadId: "thread-1")])
        defer { harness.store.close() }
        let service = harness.makeService()

        let conflict = await service.publish(
            request(threadId: "thread-2"),
            context: makeContext()
        )
        #expect(conflict.deniedCode == "thread_conflict")
        #expect(harness.sendCount == 0)

        // A matching (or omitted) request thread sends into the pinned one.
        let matching = await service.publish(
            request(intentKey: "k2", threadId: "thread-1"),
            context: makeContext()
        )
        #expect(matching.isSent)
        #expect(harness.lastSentBinding?.threadId == "thread-1")
    }

    @Test func unpinnedBindingHonorsModelSuppliedThread() async throws {
        let harness = try HardeningHarness(bindings: [makeBinding()])
        defer { harness.store.close() }
        let service = harness.makeService()

        let outcome = await service.publish(
            request(threadId: "thread-9"),
            context: makeContext()
        )
        #expect(outcome.isSent)
        #expect(harness.lastSentBinding?.threadId == "thread-9")
        let intent = try #require(try harness.store.recentOutboundIntents(limit: 1).first)
        #expect(intent.threadId == "thread-9")
    }

    @Test func oversizedIntentKeyIsRejected() async throws {
        let harness = try HardeningHarness(bindings: [makeBinding()])
        defer { harness.store.close() }
        let outcome = await harness.makeService().publish(
            request(
                intentKey: String(
                    repeating: "k",
                    count: AgentChannelPublishService.maxIntentKeyLength + 1
                )
            ),
            context: makeContext()
        )
        #expect(outcome.deniedCode == "intent_key_too_long")
    }
}

// MARK: - Approval integrity

@Suite("Approval integrity")
struct AgentChannelApprovalIntegrityTests {
    private func queuePendingIntent(
        _ service: AgentChannelPublishService
    ) async -> String? {
        let queued = await service.publish(
            request(),
            context: makeContext(source: .schedule, isUnattendedDispatch: true)
        )
        return queued.queuedIntentId
    }

    @Test func operatorApprovalRequirementQueuesEvenAutonomousBindings() async throws {
        let harness = try HardeningHarness(bindings: [makeBinding(outboundMode: .autonomous)])
        defer { harness.store.close() }
        let service = harness.makeService()

        // Unattended run where the user's global `.ask` on the publish
        // tool resolved: the binding's autonomous mode must NOT override
        // the narrower user policy.
        let outcome = await service.publish(
            request(),
            context: makeContext(
                source: .schedule,
                isUnattendedDispatch: true,
                requiresOperatorApproval: true
            )
        )
        let intentId = try #require(outcome.queuedIntentId)
        #expect(harness.sendCount == 0)

        let approved = await service.approvePendingIntent(id: intentId)
        #expect(approved.isSent)
        #expect(harness.sendCount == 1)
    }

    @Test func repointedBindingRouteInvalidatesQueuedApproval() async throws {
        let harness = try HardeningHarness(
            bindings: [makeBinding(outboundMode: .confirm)],
            connection: makeConnection(writeRoomAllowlist: ["room-1", "room-2"])
        )
        defer { harness.store.close() }
        let service = harness.makeService()
        let intentId = try #require(await queuePendingIntent(service))

        // The operator repoints the binding at a different room after the
        // item was queued: the approval saw the OLD destination, so the
        // send must be refused, not silently rerouted.
        harness.configuration = AgentChannelConfiguration(
            bindings: [makeBinding(roomId: "room-2", outboundMode: .confirm)]
        )
        let outcome = await service.approvePendingIntent(id: intentId)
        #expect(outcome.deniedCode == "binding_route_changed")
        #expect(harness.sendCount == 0)
        let intent = try #require(try harness.store.outboundIntent(id: intentId))
        #expect(intent.status == .failed)
    }

    @Test func narrowedRunSourcesInvalidateQueuedApproval() async throws {
        let harness = try HardeningHarness(bindings: [makeBinding(outboundMode: .confirm)])
        defer { harness.store.close() }
        let service = harness.makeService()
        let intentId = try #require(await queuePendingIntent(service))

        // The item was queued by a schedule run; the operator then removed
        // `schedule` from the binding's allowed sources.
        harness.configuration = AgentChannelConfiguration(
            bindings: [makeBinding(allowedSources: [.chat], outboundMode: .confirm)]
        )
        let outcome = await service.approvePendingIntent(id: intentId)
        #expect(outcome.deniedCode == "run_source_not_allowed")
        #expect(harness.sendCount == 0)
    }

    @Test func operatorCanPromoteADraftToASend() async throws {
        let harness = try HardeningHarness(bindings: [makeBinding(outboundMode: .draft)])
        defer { harness.store.close() }
        let service = harness.makeService()

        let draft = await service.publish(request(), context: makeContext())
        let draftId = try #require(draft.draftIntentId)
        #expect(harness.sendCount == 0)

        let sent = await service.sendDraftIntent(id: draftId)
        #expect(sent.isSent)
        #expect(harness.sendCount == 1)
        let intent = try #require(try harness.store.outboundIntent(id: draftId))
        #expect(intent.status == .sent)
    }

    @Test func operatorActionsAreAudited() async throws {
        let harness = try HardeningHarness(bindings: [makeBinding(outboundMode: .draft)])
        defer { harness.store.close() }
        let service = harness.makeService()

        let draft = await service.publish(request(), context: makeContext())
        let draftId = try #require(draft.draftIntentId)
        #expect(await service.discardIntent(id: draftId))

        let events = try harness.store.recentAuditEvents(limit: 10)
        #expect(
            events.contains {
                $0.action == AgentChannelPublishService.auditAction
                    && $0.reason == "operator_discarded"
            }
        )
    }
}

// MARK: - Binding lifecycle safety

@Suite("Binding lifecycle safety", .serialized)
struct AgentChannelBindingLifecycleTests {
    private func withIsolatedConfiguration(
        knownAgents: Set<UUID> = [agentA],
        body: @Sendable (AgentChannelConnectionManager) async throws -> Void
    ) async throws {
        // BOTH process-wide locks: custom-JSON runner tests guard
        // `AgentChannelConfigurationStore.overrideDirectory` with
        // `StoragePathsTestLock` while the native coexistence tests guard it
        // with `AgentChannelConfigurationTestLock` — holding only one still
        // races the other suite over the same global.
        try await StoragePathsTestLock.shared.run {
            try await AgentChannelConfigurationTestLock.shared.run {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "osaurus-agent-channel-hardening-\(UUID().uuidString)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let previousDirectory = AgentChannelConfigurationStore.overrideDirectory
                AgentChannelConfigurationStore.overrideDirectory = directory
                defer {
                    AgentChannelConfigurationStore.overrideDirectory = previousDirectory
                    try? FileManager.default.removeItem(at: directory)
                }
                let manager = AgentChannelConnectionManager(
                    agentExists: { knownAgents.contains($0) }
                )
                try await body(manager)
            }
        }
    }

    private func makeCustomConnection(id: String = "ops-webhook") -> AgentChannelConnection {
        AgentChannelConnection(
            id: id,
            name: "Ops Webhook",
            kind: .customHTTP,
            enabled: true,
            supportedActions: [.sendMessage],
            writeRoomAllowlist: ["room-1"],
            writeEnabled: true,
            customHTTP: AgentChannelCustomHTTPConfiguration(
                baseURL: "https://api.example.com",
                actions: [
                    AgentChannelAction.sendMessage.rawValue: AgentChannelCustomHTTPAction(
                        method: "POST",
                        path: "/rooms/{{input.room_id}}/messages",
                        bodyTemplate: #"{"content":{{input.content}}}"#
                    )
                ]
            )
        )
    }

    @Test func upsertBindingRejectsUnknownAgentAndConnection() async throws {
        try await withIsolatedConfiguration { manager in
            // Unknown agent (agentB is not in the known set).
            #expect(throws: AgentChannelConnectionManagerError.self) {
                try manager.upsertBinding(makeBinding(agentId: agentB))
            }
            // Known agent, but the connection id resolves to nothing
            // (neither native nor configured).
            #expect(throws: AgentChannelConnectionManagerError.self) {
                try manager.upsertBinding(makeBinding(connectionId: "ghost-connection"))
            }
            // Native connection ids always resolve.
            try manager.upsertBinding(makeBinding(connectionId: "discord"))
            #expect(manager.binding(id: "daily-report") != nil)
        }
    }

    @Test func deletingAConnectionDisablesItsBindingsPermanently() async throws {
        try await withIsolatedConfiguration { manager in
            try manager.upsertConnection(makeCustomConnection())
            try manager.upsertBinding(makeBinding(connectionId: "ops-webhook"))
            #expect(manager.binding(id: "daily-report")?.enabled == true)

            try manager.deleteConnection(id: "ops-webhook")
            let disabled = try #require(manager.binding(id: "daily-report"))
            #expect(disabled.enabled == false)

            // Recreating a connection under the SAME id must not silently
            // reactivate the old route.
            try manager.upsertConnection(makeCustomConnection())
            #expect(manager.binding(id: "daily-report")?.enabled == false)
        }
    }

    @Test func deletingAnAgentRemovesOnlyItsBindings() async throws {
        try await withIsolatedConfiguration(knownAgents: [agentA, agentB]) { manager in
            try manager.upsertBinding(makeBinding(id: "agent-a-binding", agentId: agentA))
            try manager.upsertBinding(makeBinding(id: "agent-b-binding", agentId: agentB))

            try manager.deleteBindings(agentId: agentA)
            #expect(manager.binding(id: "agent-a-binding") == nil)
            #expect(manager.binding(id: "agent-b-binding") != nil)
        }
    }

    @Test func importDisablesAutonomousAndUnresolvedBindings() async throws {
        try await withIsolatedConfiguration { manager in
            let imported = AgentChannelConfiguration(
                bindings: [
                    makeBinding(id: "autonomous-import", outboundMode: .autonomous),
                    makeBinding(id: "confirm-import", outboundMode: .confirm),
                    makeBinding(id: "ghost-agent", agentId: agentB, outboundMode: .confirm),
                    makeBinding(
                        id: "ghost-connection",
                        connectionId: "nonexistent",
                        outboundMode: .confirm
                    ),
                ]
            )
            let encoder = JSONEncoder()
            try manager.importConfigurationData(encoder.encode(imported))

            // An imported file is a claim, not an approval: autonomous
            // bindings and bindings with unresolved references arrive
            // disabled; a resolvable confirm binding stays enabled.
            #expect(manager.binding(id: "autonomous-import")?.enabled == false)
            #expect(manager.binding(id: "confirm-import")?.enabled == true)
            #expect(manager.binding(id: "ghost-agent")?.enabled == false)
            #expect(manager.binding(id: "ghost-connection")?.enabled == false)
        }
    }
}

// MARK: - Native-only manifest visibility

@Suite("Native-only channel manifest visibility", .serialized)
struct AgentChannelNativeManifestVisibilityTests {
    /// `hasAnyConfiguredAgentChannel` gates whether the `agent_channel_*`
    /// family enters the enabled-capabilities manifest. It must see native
    /// provider rooms and outbound bindings, not just enabled custom
    /// connections (the original bug), and stay false when nothing at all
    /// is configured.
    @Test func nativeRoomsAndBindingsBothLightUpTheManifest() async throws {
        try await StoragePathsTestLock.shared.run {
            try await AgentChannelConfigurationTestLock.shared.run {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "osaurus-native-manifest-\(UUID().uuidString)",
                    isDirectory: true
                )
                let previousAgentChannel = AgentChannelConfigurationStore.overrideDirectory
                let previousDiscord = DiscordConnectionConfigurationStore.overrideDirectory
                let previousSlack = SlackConnectionConfigurationStore.overrideDirectory
                let previousTelegram = TelegramConnectionConfigurationStore.overrideDirectory
                let previousIMessage = IMessageConnectionConfigurationStore.overrideDirectory
                AgentChannelConfigurationStore.overrideDirectory =
                    root.appendingPathComponent("agent-channels")
                DiscordConnectionConfigurationStore.overrideDirectory =
                    root.appendingPathComponent("discord")
                SlackConnectionConfigurationStore.overrideDirectory =
                    root.appendingPathComponent("slack")
                TelegramConnectionConfigurationStore.overrideDirectory =
                    root.appendingPathComponent("telegram")
                IMessageConnectionConfigurationStore.overrideDirectory =
                    root.appendingPathComponent("imessage")
                defer {
                    AgentChannelConfigurationStore.overrideDirectory = previousAgentChannel
                    DiscordConnectionConfigurationStore.overrideDirectory = previousDiscord
                    SlackConnectionConfigurationStore.overrideDirectory = previousSlack
                    TelegramConnectionConfigurationStore.overrideDirectory = previousTelegram
                    IMessageConnectionConfigurationStore.overrideDirectory = previousIMessage
                    try? FileManager.default.removeItem(at: root)
                }

                // Nothing configured anywhere → no manifest entry.
                await MainActor.run {
                    #expect(
                        !SystemPromptComposer.hasAnyConfiguredAgentChannel(
                            configuration: AgentChannelConfiguration()
                        )
                    )
                }

                // A native provider with configured rooms is enough, even
                // with zero custom connections (the original regression).
                try SlackConnectionConfigurationStore.save(
                    SlackConnectionConfiguration(readableChannelIds: ["C-NATIVE"])
                )
                await MainActor.run {
                    #expect(
                        SystemPromptComposer.hasAnyConfiguredAgentChannel(
                            configuration: AgentChannelConfiguration()
                        )
                    )
                }
                try SlackConnectionConfigurationStore.save(SlackConnectionConfiguration())

                // iMessage allowlisted chats light up the manifest too, so
                // iMessage-only agents discover the channel tools.
                try IMessageConnectionConfigurationStore.save(
                    IMessageConnectionConfiguration(readableChatIds: ["iMessage;-;+15551234567"])
                )
                await MainActor.run {
                    #expect(
                        SystemPromptComposer.hasAnyConfiguredAgentChannel(
                            configuration: AgentChannelConfiguration()
                        )
                    )
                }
                try IMessageConnectionConfigurationStore.save(IMessageConnectionConfiguration())

                // An outbound binding alone is also enough.
                await MainActor.run {
                    #expect(
                        SystemPromptComposer.hasAnyConfiguredAgentChannel(
                            configuration: AgentChannelConfiguration(
                                bindings: [makeBinding()]
                            )
                        )
                    )
                }
            }
        }
    }
}

// MARK: - Unattended `.ask` queue disposition

/// Contextual permissioned probe with a configurable unattended-ask
/// disposition, mirroring `agent_channel_publish`'s shape.
private final class QueueDispositionProbeTool: OsaurusTool, ContextualPermissionedTool,
    @unchecked Sendable
{
    let name: String
    let description = "Test-only unattended ask queue probe."
    let parameters: JSONValue? = nil
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .ask
    let queuesUnattendedAsk: Bool

    private(set) var executions = 0

    init(name: String, queuesUnattendedAsk: Bool) {
        self.name = name
        self.queuesUnattendedAsk = queuesUnattendedAsk
    }

    func resolveContextualPermissionPolicy(argumentsJSON: String) async -> ToolPermissionPolicy {
        .ask
    }

    func unattendedAskQueuesForApproval(argumentsJSON: String) async -> Bool {
        queuesUnattendedAsk
    }

    func execute(argumentsJSON: String) async throws -> String {
        executions += 1
        return ToolEnvelope.success(tool: name, text: "queued")
    }
}

@MainActor
@Suite("Unattended ask queue disposition")
struct UnattendedAskQueueDispositionTests {
    @Test func publishToolDeclaresQueueDisposition() async {
        let tool = AgentChannelPublishTool(loadConfiguration: { AgentChannelConfiguration() })
        #expect(await tool.unattendedAskQueuesForApproval(argumentsJSON: "{}"))
    }

    @Test func queueCapableToolProceedsIntoItsBodyOnUnattendedAsk() async throws {
        let tool = QueueDispositionProbeTool(
            name: "test_unattended_queue_probe",
            queuesUnattendedAsk: true
        )
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        // Unattended dispatch + `.ask`: instead of stalling on a card nobody
        // can answer, the gate lets the tool body run — the body is
        // responsible for queuing the side effect for operator approval.
        let result = try await ChatExecutionContext.$isUnattendedDispatch.withValue(true) {
            try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
        }
        #expect(tool.executions == 1)
        #expect(!ToolEnvelope.isError(result))
    }

    @Test func headlessDenialStillWinsOverQueueDisposition() async {
        let tool = QueueDispositionProbeTool(
            name: "test_unattended_queue_denied_probe",
            queuesUnattendedAsk: true
        )
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        // `denyUnapprovedToolPrompts` (headless evals, external MCP) is a
        // stricter gate than the queue disposition: nothing may proceed.
        await #expect(throws: (any Error).self) {
            _ = try await ChatExecutionContext.$isUnattendedDispatch.withValue(true) {
                try await ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
                    try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
                }
            }
        }
        #expect(tool.executions == 0)
    }
}
