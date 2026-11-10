//
//  EventSourceSubstrateTests.swift
//  osaurusTests
//
//  The source substrate shared by every automation kind: the descriptor
//  registry, adapter dispatch from EventManager, the dedupe policy and its
//  legacy decode, durable seen keys across a relaunch, adapter state, the
//  folder baseline surviving a relaunch, and source connections.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Registry

@MainActor
struct EventSourceRegistryTests {
    @Test func everyKindHasADescriptorAndAnAdapter() throws {
        let (manager, _) = try EventPipelineFixtures.manager()
        for kind in EventSourceKind.allCases {
            #expect(kind.descriptor.kind == kind)
            #expect(manager.adapter(for: kind).kind == kind)
            #expect(!kind.descriptor.displayName.isEmpty)
            #expect(!kind.descriptor.payloadRoot.isEmpty)
        }
        #expect(Set(manager.adapters.map(\.kind)) == Set(EventSourceKind.allCases))
    }

    @Test func payloadRootsComeFromTheDescriptors() {
        let roots = Set(EventSourceKind.allCases.map(\.descriptor.payloadRoot))
        #expect(EventTemplate.payloadRoots == roots.union(EventSourceRegistry.commonPayloadRoots))
    }

    @Test func defaultsPerKindKeepTodaysBehavior() {
        #expect(EventSourceKind.schedule.descriptor.dedupeMode == .window)
        #expect(EventSourceKind.folder.descriptor.dedupeMode == .none)
        #expect(EventSourceKind.folder.descriptor.emitMode == .perBatch)
        #expect(EventSourceKind.webhook.descriptor.emitMode == .perItem)
        #expect(EventDeliveryPolicy.defaults(for: .folder).dedupe == .none)
        #expect(EventDeliveryPolicy.defaults(for: .webhook).dedupe == .window(600))
        #expect(EventDeliveryPolicy.defaults(for: .webhook).maxQueued == 20)
        #expect(EventDeliveryPolicy.defaults(for: .schedule).maxQueued == 0)
        #expect(EventDeliveryPolicy.defaults(for: .channelMessage).mode == .perConversation)
        #expect(EventDeliveryPolicy.defaults(for: .email).dedupe == .durable)
        #expect(EventDeliveryPolicy.defaults(for: .email).mode == .serial)
        #expect(EventSourceRegistry.pickerKinds == [.schedule, .folder, .webhook, .rss, .sse, .runFailed, .app])
        #expect(EventSourceRegistry.listKinds == [.schedule, .folder, .webhook, .rss, .sse, .runFailed, .app, .email])
        #expect(EventSourceTemplate.triggers == EventSourceRegistry.pickerKinds.map { .source($0) })
        #expect(EventSourceTemplate.providerWebhooks.count == WebhookProvider.allCases.count - 1)
        #expect(EventDeliveryPolicy.defaults(for: .rss).dedupe == .durable)
        #expect(EventDeliveryPolicy.defaults(for: .app).dedupe == .none)
        let feedEvent = OsaurusEvent(
            name: "Feed", source: .rss(RSSSourceConfig(url: "https://example.com/f")),
            action: EventPipelineFixtures.agentAction())
        let feedPayload = EventPayload.feed(
            event: feedEvent, firedAt: Date(), url: "https://example.com/f", feedTitle: "F",
            item: FeedItem.example(now: Date()))
        #expect(EventSourceKind.rss.descriptor.untrustedContent(payload: feedPayload, eventName: "Feed") != nil)
        #expect(EventSourceKind.runFailed.descriptor.untrustedContent(payload: feedPayload, eventName: "Feed") == nil)
        #expect(AgentEventAction.defaultFreshSession(for: .folder) == false)
        #expect(AgentEventAction.defaultFreshSession(for: .webhook) == true)
    }

    @Test func historyChipsComeFromTheRegistry() {
        #expect(
            AutomationHistoryFilter.Source.allCases.map(\.id)
                == ["all", "schedule", "folder", "webhook", "rss", "sse", "run_failed", "app", "channel_message"])
        #expect(AutomationHistoryFilter.Source.messages.displayName == L("Messages"))
    }
}

// MARK: - Dedupe policy

struct EventDedupePolicyTests {
    private func decode(_ json: String) throws -> EventDeliveryPolicy {
        try JSONDecoder().decode(EventDeliveryPolicy.self, from: Data(json.utf8))
    }

    @Test func legacyFilesDecodeTheirWindow() throws {
        #expect(try decode(#"{"mode":"serial","dedupeWindowSeconds":600}"#).dedupe == .window(600))
        #expect(try decode(#"{"mode":"serial","dedupeWindowSeconds":0}"#).dedupe == .none)
        #expect(try decode(#"{"mode":"serial"}"#).dedupe == .window(EventDedupePolicy.defaultWindowSeconds))
    }

    @Test func theModeWinsOverTheWindow() throws {
        #expect(try decode(#"{"dedupe":"durable","dedupeWindowSeconds":600}"#).dedupe == .durable)
        #expect(try decode(#"{"dedupe":"none","dedupeWindowSeconds":600}"#).dedupe == .none)
        #expect(try decode(#"{"dedupe":"window","dedupeWindowSeconds":120}"#).dedupe == .window(120))
    }

    @Test func roundTripsAndKeepsTheLegacyField() throws {
        for policy in [EventDedupePolicy.none, .window(90), .durable] {
            let encoded = try JSONEncoder().encode(EventDeliveryPolicy(dedupe: policy))
            #expect(try JSONDecoder().decode(EventDeliveryPolicy.self, from: encoded).dedupe == policy)
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            #expect(object?["dedupeWindowSeconds"] != nil)
        }
        #expect(EventDeliveryPolicy(dedupeWindowSeconds: 0).dedupe == .none)
    }
}

// MARK: - Ledger v2

struct EventSourceLedgerTests {
    @Test func seenKeysInsertOnceAndPruneByAgeAndCap() throws {
        let db = EventRunDatabase()
        try db.openInMemory()
        let id = UUID()
        let first = UUID()
        let now = Date()
        try db.insertSeenKey(eventId: id, dedupeKey: "k", runId: first, at: now)
        try db.insertSeenKey(eventId: id, dedupeKey: "k", runId: UUID(), at: now)
        #expect(try db.seenKey(eventId: id, dedupeKey: "k") == first)
        #expect(try db.seenKey(eventId: UUID(), dedupeKey: "k") == nil)

        let other = UUID()
        try db.insertSeenKey(
            eventId: other, dedupeKey: "old", runId: UUID(), at: now.addingTimeInterval(-EventRunDatabase.seenKeyRetentionAge - 60))
        try db.pruneSeenKeys(now: now)
        #expect(try db.seenKey(eventId: other, dedupeKey: "old") == nil)
        #expect(try db.seenKeyCount(eventId: id) == 1)

        try db.deleteRuns(eventId: id)
        #expect(try db.seenKey(eventId: id, dedupeKey: "k") == nil)
    }

    @Test func sourceStateIsScopedAndClearedWithTheEvent() throws {
        let db = EventRunDatabase()
        try db.openInMemory()
        let id = UUID()
        let scope = EventRunDatabase.eventScopePrefix(id) + ":folder"
        let shared = "conn:abc:INBOX"
        try db.setSourceState(.object(["cursor": .number(1)]), scope: scope)
        try db.setSourceState(.object(["cursor": .number(2)]), scope: scope)
        try db.setSourceState(.string("x"), scope: shared)
        #expect(try db.sourceState(scope: scope) == .object(["cursor": .number(2)]))

        try db.deleteRuns(eventId: id)
        #expect(try db.sourceState(scope: scope) == nil)
        #expect(try db.sourceState(scope: shared) == .string("x"))
        try db.deleteSourceState(scope: shared)
        #expect(try db.sourceState(scope: shared) == nil)
    }
}

// MARK: - Durable dedupe

@MainActor
struct EventDurableDedupeTests {
    private func flush() async {
        await withCheckedContinuation { continuation in EventManager.ioQueue.async { continuation.resume() } }
    }

    @Test func aDurableKeyIsADuplicateAfterARelaunch() async throws {
        let ledger = EventRunDatabase()
        try ledger.openInMemory()
        let manager = EventManager(ledger: ledger, persistsToDisk: false)
        let runner = FakeEventRunner()
        runner.install(on: manager)
        runner.hold = true
        let event = manager.create(
            OsaurusEvent(
                name: "Mail", source: .webhook(WebhookSourceConfig(verification: .none)),
                action: EventPipelineFixtures.agentAction(), delivery: EventDeliveryPolicy(dedupe: .durable)))
        let first = manager.submit(EventOccurrence(eventId: event.id, payload: .object([:]), dedupeKey: "m1"))
        #expect(first.status == .running)
        // Written at admission, while the run is still going.
        await flush()
        #expect(try ledger.seenKey(eventId: event.id, dedupeKey: "m1") == first.runId)
        runner.release()
        _ = await EventPipelineFixtures.settled(manager, first.runId)

        // The ledger rows age out; the seen key does not.
        try ledger.pruneAll(now: Date().addingTimeInterval(EventRunDatabase.retentionAge + 3600))
        #expect(try ledger.runs(eventId: event.id).isEmpty)

        let relaunched = EventManager(ledger: ledger, persistsToDisk: false)
        let runner2 = FakeEventRunner()
        runner2.install(on: relaunched)
        _ = relaunched.create(event)
        let again = relaunched.submit(EventOccurrence(eventId: event.id, payload: .object([:]), dedupeKey: "m1"))
        #expect(again.status == .duplicate)
        #expect(again.reason == "duplicate_of:\(first.runId.uuidString)")
        let fresh = relaunched.submit(EventOccurrence(eventId: event.id, payload: .object([:]), dedupeKey: "m2"))
        #expect(fresh.status == .running)
        _ = await EventPipelineFixtures.settled(relaunched, fresh.runId)
    }

    @Test func noDedupeNeverDedupes() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let event = manager.create(
            OsaurusEvent(
                name: "Stream", source: .webhook(WebhookSourceConfig(verification: .none)),
                action: EventPipelineFixtures.agentAction(),
                delivery: EventDeliveryPolicy(mode: .parallel, maxConcurrent: 4, dedupe: EventDedupePolicy.none)))
        let a = manager.submit(EventOccurrence(eventId: event.id, payload: .object([:]), dedupeKey: "same"))
        let b = manager.submit(EventOccurrence(eventId: event.id, payload: .object([:]), dedupeKey: "same"))
        #expect(a.status == .running)
        #expect(b.status == .running)
        await runner.waitForFires(2)
    }

    @Test func manualFiresIgnoreDurableKeys() async throws {
        let (manager, _) = try EventPipelineFixtures.manager()
        let event = manager.create(
            OsaurusEvent(
                name: "Mail", source: .webhook(WebhookSourceConfig(verification: .none)),
                action: EventPipelineFixtures.agentAction(), delivery: EventDeliveryPolicy(dedupe: .durable)))
        let first = manager.submit(EventOccurrence(eventId: event.id, payload: .object([:]), dedupeKey: "m1"))
        _ = await EventPipelineFixtures.settled(manager, first.runId)
        let manual = manager.submit(
            EventOccurrence(eventId: event.id, payload: .object([:]), trigger: .manual, dedupeKey: "m1"))
        #expect(manual.status != .duplicate)
    }
}

// MARK: - Adapter dispatch

@MainActor
final class RecordingAdapter: EventSourceAdapter {
    let kind: EventSourceKind
    var calls: [String] = []
    var installError: Error?

    init(kind: EventSourceKind) { self.kind = kind }

    func start() async { calls.append("start") }
    func stop() { calls.append("stop") }
    func reconcile(_ events: [OsaurusEvent]) async { calls.append("reconcile:\(events.count)") }
    func forget(_ eventId: UUID) { calls.append("forget") }
    func cancel(_ eventId: UUID) { calls.append("cancel") }
    func install(_ event: OsaurusEvent) async throws {
        calls.append("install")
        if let installError { throw installError }
    }
    func uninstall(_ event: OsaurusEvent) async { calls.append("uninstall") }
    func reconcileInstalled(_ events: [OsaurusEvent]) async { calls.append("reconcileInstalled:\(events.count)") }
    func sample(for event: OsaurusEvent) async -> JSONValue? {
        calls.append("sample")
        return .string("latest")
    }
    func fireNow(_ event: OsaurusEvent, sample: JSONValue?) async -> EventFireResult {
        calls.append("fireNow:\(sample?.stringValue ?? "nil")")
        return EventFireResult(runId: UUID(), status: .running, reason: nil)
    }
    func status(_ eventId: UUID) -> EventSourceStatus { EventSourceStatus(note: "recorded") }
}

@MainActor
struct EventSourceAdapterDispatchTests {
    private func manager(_ adapter: RecordingAdapter) throws -> EventManager {
        let (manager, _) = try EventPipelineFixtures.manager()
        manager.adapters = manager.adapters.map { $0.kind == adapter.kind ? adapter : $0 }
        return manager
    }

    private func settle() async {
        for _ in 0 ..< 10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    private func webhookEvent(enabled: Bool = true) -> OsaurusEvent {
        OsaurusEvent(
            name: "Hook", isEnabled: enabled, source: .webhook(WebhookSourceConfig(verification: .none)),
            action: EventPipelineFixtures.agentAction())
    }

    @Test func lifecycleCallsReachTheKindsAdapter() async throws {
        let adapter = RecordingAdapter(kind: .webhook)
        let manager = try manager(adapter)
        let event = manager.create(webhookEvent())
        await settle()
        #expect(adapter.calls.contains("install"))
        #expect(adapter.calls.contains { $0.hasPrefix("reconcile:") })

        adapter.calls.removeAll()
        manager.setEnabled(event.id, enabled: false)
        await settle()
        #expect(adapter.calls.contains("cancel"))
        #expect(adapter.calls.contains("uninstall"))
        #expect(!adapter.calls.contains("install"))

        adapter.calls.removeAll()
        manager.setEnabled(event.id, enabled: true)
        await settle()
        #expect(adapter.calls.contains("install"))

        adapter.calls.removeAll()
        #expect(manager.status(of: event.id).note == "recorded")
        let fired = await manager.fireNow(event.id)
        #expect(fired.status == .running)
        #expect(adapter.calls == ["sample", "fireNow:latest"])

        adapter.calls.removeAll()
        _ = await manager.fireNow(event.id, samplePayload: .string("given"))
        #expect(adapter.calls == ["fireNow:given"])

        adapter.calls.removeAll()
        #expect(manager.delete(id: event.id))
        await settle()
        #expect(adapter.calls.contains("forget"))
        #expect(adapter.calls.contains("uninstall"))
    }

    @Test func aDisabledEventIsNotInstalledAndEditsDoNotReinstall() async throws {
        let adapter = RecordingAdapter(kind: .webhook)
        let manager = try manager(adapter)
        var event = manager.create(webhookEvent(enabled: false))
        await settle()
        #expect(!adapter.calls.contains("install"))

        manager.setEnabled(event.id, enabled: true)
        await settle()
        adapter.calls.removeAll()
        event = try #require(manager.event(for: event.id))
        event.name = "Renamed"
        manager.update(event)
        await settle()
        #expect(!adapter.calls.contains("install"))
        #expect(!adapter.calls.contains("uninstall"))
    }

    @Test func replacingTheSourceForgetsAndUninstallsOnTheOldAdapter() async throws {
        let old = RecordingAdapter(kind: .webhook)
        let new = RecordingAdapter(kind: .schedule)
        let (manager, _) = try EventPipelineFixtures.manager()
        manager.adapters = manager.adapters.map {
            switch $0.kind {
            case .webhook: old
            case .schedule: new
            default: $0
            }
        }
        var event = manager.create(webhookEvent())
        await settle()
        old.calls.removeAll()
        event.source = .schedule(ScheduleSourceConfig(frequency: .hourly(minute: 0)))
        manager.update(event)
        await settle()
        #expect(old.calls.contains("forget"))
        #expect(old.calls.contains("uninstall"))
        #expect(new.calls.contains("install"))
    }

    @Test func anInstallFailureShowsOnTheStatusInsteadOfDisabling() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "provider said no" } }
        let adapter = RecordingAdapter(kind: .webhook)
        adapter.installError = Boom()
        let manager = try manager(adapter)
        let event = manager.create(webhookEvent())
        await settle()
        #expect(manager.sourceStatus[event.id]?.lastError == "provider said no")
        #expect(manager.sourceStatus[event.id]?.installed == false)
        #expect(manager.event(for: event.id)?.isEnabled == true)
    }

    @Test func launchStartsReconcilesAndChecksInstallsPerAdapter() async throws {
        let adapter = RecordingAdapter(kind: .webhook)
        let manager = try manager(adapter)
        manager.start()
        await manager.awaitLoaded()
        await settle()
        #expect(adapter.calls.prefix(3) == ["reconcile:0", "start", "reconcileInstalled:0"])
        manager.stop()
        #expect(adapter.calls.last == "stop")
    }
}

// MARK: - Folder baseline

@MainActor
struct FolderBaselinePersistenceTests {
    @Test func changesWhileClosedFireOncePassAtLaunch() async throws {
        let folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("evt-baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("a".utf8).write(to: folder.appendingPathComponent("old.txt"))

        let ledger = EventRunDatabase()
        try ledger.openInMemory()
        let first = EventManager(ledger: ledger, persistsToDisk: false)
        let firstRunner = FakeEventRunner()
        firstRunner.install(on: first)
        first.start()
        await first.awaitLoaded()
        let event = first.create(
            OsaurusEvent(
                name: "Inbox",
                source: .folder(FolderSourceConfig(path: folder.path, responsiveness: .fast, settleSeconds: 0.05)),
                action: EventPipelineFixtures.agentAction()))
        let scope = FolderEventSource.baselineScope(event.id)
        for _ in 0 ..< 200 where (try? ledger.sourceState(scope: scope)) == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(try ledger.sourceState(scope: scope) != nil)
        first.stop()

        // The app is closed; a file arrives.
        try Data("b".utf8).write(to: folder.appendingPathComponent("new.txt"))

        let second = EventManager(ledger: ledger, persistsToDisk: false)
        let runner = FakeEventRunner()
        runner.install(on: second)
        second.start()
        await second.awaitLoaded()
        _ = second.create(event)
        await runner.waitForFires(1)
        let fired = try #require(runner.fired.first)
        #expect(fired.trigger == .source)
        #expect(fired.payload.value(atPath: "folder.changed_paths")?.arrayValue?.compactMap(\.stringValue) == ["new.txt"])
        for _ in 0 ..< 200 where second.folderPhases[event.id] != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        second.stop()
        #expect(firstRunner.fired.isEmpty)
    }

    @Test func noChangeWhileClosedFiresNothing() async throws {
        let folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("evt-baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("a".utf8).write(to: folder.appendingPathComponent("old.txt"))

        let ledger = EventRunDatabase()
        try ledger.openInMemory()
        let first = EventManager(ledger: ledger, persistsToDisk: false)
        FakeEventRunner().install(on: first)
        first.start()
        await first.awaitLoaded()
        let event = first.create(
            OsaurusEvent(
                name: "Inbox",
                source: .folder(FolderSourceConfig(path: folder.path, responsiveness: .fast, settleSeconds: 0.05)),
                action: EventPipelineFixtures.agentAction()))
        let scope = FolderEventSource.baselineScope(event.id)
        for _ in 0 ..< 200 where (try? ledger.sourceState(scope: scope)) == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(try ledger.sourceState(scope: scope) != nil)
        first.stop()

        let second = EventManager(ledger: ledger, persistsToDisk: false)
        let runner = FakeEventRunner()
        runner.install(on: second)
        second.start()
        await second.awaitLoaded()
        _ = second.create(event)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(runner.fired.isEmpty)
        second.stop()
    }
}

// MARK: - Connections

@MainActor
struct SourceConnectionStoreTests {
    @Test func deletingAConnectionInUseIsRefused() {
        SourceCredentialVault.resetForTesting()
        let store = SourceConnectionStore(persistsToDisk: false)
        let connection = store.save(
            SourceConnection(displayName: "Linear", config: .apiToken(APITokenConnectionConfig(service: "linear"))))
        #expect(SourceCredentialVault.save("tok", connectionId: connection.id, field: SourceCredentialVault.tokenField))
        var users: [OsaurusEvent] = [
            OsaurusEvent(name: "Issues", source: .webhook(WebhookSourceConfig()), action: EventPipelineFixtures.agentAction())
        ]
        store.dependents = { _ in users }
        #expect(store.delete(id: connection.id) == .inUse(["Issues"]))
        #expect(store.connection(id: connection.id) != nil)

        users = []
        #expect(store.delete(id: connection.id) == .deleted)
        #expect(store.connection(id: connection.id) == nil)
        #expect(!SourceCredentialVault.has(connectionId: connection.id, field: SourceCredentialVault.tokenField))
        #expect(store.delete(id: connection.id) == .notFound)
    }

    @Test func connectionsRoundTripThroughJSON() throws {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let connection = SourceConnection(
            displayName: "Linear", config: .apiToken(APITokenConnectionConfig(service: "linear")),
            createdAt: stamp, updatedAt: stamp)
        let data = try EventStore.encoder.encode(connection)
        let decoded = try EventStore.decoder.decode(SourceConnection.self, from: data)
        #expect(decoded == connection)
        #expect(decoded.type == .apiToken)
        #expect(decoded.id == decoded.id.lowercased())
    }
}
