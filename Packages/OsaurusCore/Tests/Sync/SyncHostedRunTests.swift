//
//  SyncHostedRunTests.swift
//  OsaurusCoreTests
//
//  Hosted runs: each Mac's agent directory reaches the others and stays out
//  of chats, the host answers a request once and declines what it can't
//  run, a hosted run's approvals wait for the device the user chats on, and
//  the caller knows when it's waiting.
//

import Foundation
import OsaurusSync
import Testing
import os

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SyncHostedRunTests {
    private final class Recorder<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ new: [T]) { lock.withLock { items += new } }
        var all: [T] { lock.withLock { items } }
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 20,
        _ condition: () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition() {
            if Date() > deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func entry(_ name: String) -> SyncHostedRunContract.DirectoryEntry {
        SyncHostedRunContract.DirectoryEntry(
            id: UUID().uuidString.lowercased(),
            address: "0xabc",
            name: name,
            description: nil,
            avatar: nil
        )
    }

    // MARK: - Directory

    @Test
    func theDirectoryOffersUserAgentsAndTheMarkedDefaultOnlyWhenHosting() {
        let researcher = Agent(name: "Researcher", agentAddress: "0xABCDEF")
        let otherBuiltIn = Agent(name: "Helper", isBuiltIn: true)
        let entries = SyncAgentDirectory.entries(agents: [.default, otherBuiltIn, researcher], hosting: true)
        #expect(entries.count == 2)
        let mine = try? #require(entries.first { $0.id == researcher.id.uuidString.lowercased() })
        #expect(mine?.address == "0xabcdef")
        #expect(mine?.isDefault == nil)
        let fallback = entries.first { $0.id == Agent.defaultId.uuidString.lowercased() }
        #expect(fallback?.isDefault == true)
        #expect(!entries.contains { $0.name == "Helper" })
        #expect(SyncAgentDirectory.entries(agents: [researcher], hosting: false).isEmpty)
    }

    @Test
    func aDirectoryReachesTheOtherDeviceAndStaysOutOfChats() async throws {
        try await ChatHistoryTestStorage.run {
            let mac = try SyncService.shared.open()
            try await mac.resume()
            defer { SyncService.shared.close() }

            let otherDirectory = OsaurusPaths.root().appendingPathComponent("other-mac/sync", isDirectory: true)
            try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
            var network = localNetworkConfig()
            network.enabled = true
            let peer = try SyncCore.open(
                dataDirectory: otherDirectory,
                deviceName: "Other Mac",
                network: network,
                keyStore: SyncKeyStores.make(dataDirectory: otherDirectory)
            )
            let events = Recorder<CoreEvent>()
            peer.setListener { events.append([$0]) }
            try mac.addPeerAddress(address: #require(peer.localAddress()))
            try peer.addPeerAddress(address: #require(mac.localAddress()))
            let offer = try mac.pairingOffer(ttlMs: 300_000)
            try await peer.pairWithOffer(payload: offer.payload)
            try await SyncTestPairing.confirm(host: mac, joiner: peer)
            try await waitUntil("paired") {
                events.all.contains { if case .paired = $0 { return true } else { return false } }
            }

            // Nothing to offer and nothing offered before: no directory at all.
            try SyncAgentDirectory.publish([], core: mac, deviceName: "Studio")
            #expect(try mac.conversations().isEmpty)

            let researcher = entry("Researcher")
            try SyncAgentDirectory.publish([researcher], core: mac, deviceName: "Studio")
            let directories = try mac.conversations()
            #expect(directories.count == 1)
            #expect(directories.first.map(SyncConversationMapper.isAppInternal) == true)
            // Unchanged agents don't write again.
            let updated = try #require(directories.first?.appData(SyncHostedRunContract.directoryNamespace))
            try SyncAgentDirectory.publish([researcher], core: mac, deviceName: "Studio")
            #expect(try mac.conversations().first?.appData(SyncHostedRunContract.directoryNamespace) == updated)

            #expect(SyncAgentDirectory.hosts(core: mac, devices: try mac.devices()).isEmpty, "its own directory")
            try await waitUntil("directory on the other device") {
                !SyncAgentDirectory.hosts(core: peer, devices: try peer.devices()).isEmpty
            }
            let host = try #require(SyncAgentDirectory.hosts(core: peer, devices: try peer.devices()).first)
            #expect(host.device == mac.deviceKey())
            #expect(host.agents == [researcher])

            // The directory never shows as a chat.
            let store = SyncConversationStore.shared
            store.invalidateCaches()
            #expect(store.loadAllMetadata().isEmpty)
            #expect(store.sessionId(forScope: try #require(directories.first?.scope)) == nil)

            // Turning hosting off empties the directory, and the host drops out.
            try SyncAgentDirectory.publish([], core: mac, deviceName: "Studio")
            try await waitUntil("empty directory on the other device") {
                SyncAgentDirectory.hosts(core: peer, devices: try peer.devices()).isEmpty
            }
            try await peer.close()
        }
    }

    // MARK: - Contract records

    @Test
    func approvalAnswersSkipValuesTheyDontKnow() throws {
        let json = Data(#"{"v":1,"answers":{"a":"allowOnce","b":"allowForever","c":"denied"}}"#.utf8)
        let answers = try JSONDecoder().decode(SyncHostedRunContract.ApprovalAnswers.self, from: json)
        #expect(answers.answers == ["a": .allowOnce, "c": .denied])
    }

    @Test
    func theLedgerKeepsRunningAndRecentRuns() {
        let now: Int64 = 10_000_000_000_000
        let old = now - SyncHostRunner.Ledger.retentionMs - 1
        var ledger = SyncHostRunner.Ledger(runs: [
            "running": .init(sessionId: UUID(), scope: "s", state: .running, updatedMs: old),
            "old": .init(sessionId: UUID(), scope: "s", state: .done, updatedMs: old),
            "recent": .init(sessionId: UUID(), scope: "s", state: .done, updatedMs: now - 1000),
        ])
        ledger.prune(nowMs: now)
        #expect(Set(ledger.runs.keys) == ["running", "recent"])
    }

    // MARK: - Caller

    @Test
    func theCallerWaitsUntilTheHostAnswersOrFinishes() {
        let session = ChatSession()
        session.hostDevice = "studio"
        session.sessionId = UUID()
        let question = ChatTurn(role: .user, content: "Summarize the report")
        question.hostRun = HostRunRequest(device: "studio")
        session.turns = [question]
        #expect(session.pendingHostedTurn === question)

        session.hostRunState = SyncHostedRunContract.HostRun(
            turn: question.id.uuidString.lowercased(),
            state: .running,
            updatedMs: 1
        )
        session.turns.append(ChatTurn(role: .assistant, content: "Working…"))
        #expect(session.isWaitingOnHost, "the host's state outranks a partial reply")

        session.hostRunState?.state = .done
        #expect(!session.isWaitingOnHost)

        session.hostRunState = nil
        #expect(!session.isWaitingOnHost, "an assistant turn answered it")

        session.turns.removeLast()
        session.hostStopRequest = HostStopRequest(
            turnId: question.id,
            at: Date().addingTimeInterval(-ChatSession.hostStopGrace - 1)
        )
        #expect(!session.isWaitingOnHost, "a stop the host never confirmed unlocks after the grace")

        session.hostDevice = nil
        session.hostStopRequest = nil
        #expect(!session.isWaitingOnHost, "not a hosted chat")
    }

    @Test
    func pickingAHostedAgentOpensItsChat() async throws {
        try await ChatHistoryTestStorage.run {
            let agentId = UUID()
            var researcher = entry("Researcher")
            researcher.id = agentId.uuidString.lowercased()
            SyncAgentDirectory.shared._setHostsForTesting([.init(device: "studio", name: "Studio", agents: [researcher])])
            defer { SyncAgentDirectory.shared._setHostsForTesting([]) }
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            window.switchToHostedAgent(device: "studio", agentId: agentId)
            #expect(window.activeScope == .hosted(device: "studio", agentId: agentId), "from a blank chat")
            #expect(window.session.hostDevice == "studio")
            #expect(window.tabs.count == 1)
            #expect(window.effectiveChatIdentity.name == "Researcher", "the thread is headed by the host's agent")
            #expect(window.effectiveChatIdentity.isRemote)

            window.switchAgent(to: Agent.defaultId)
            window.session.turns.append(ChatTurn(role: .user, content: "local work"))
            let localTab = window.activeTabId
            window.switchToHostedAgent(device: "studio", agentId: agentId)
            #expect(window.activeScope == .hosted(device: "studio", agentId: agentId), "from a chat with turns")
            #expect(window.activeTabId != localTab)
            #expect(window.session.hostDevice == "studio")
            #expect(window.session.agentId == agentId)
            #expect(window.scopedTabs.map(\.id) == [window.activeTabId], "the local tab is in another strip")

            window.switchAgent(to: Agent.defaultId)
            #expect(window.activeTabId == localTab, "back to the local chat")
        }
    }

    @Test
    func aHostedTabKeepsTheWindowOnTheDefaultAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let agentId = UUID()
            var researcher = entry("Researcher")
            researcher.id = agentId.uuidString.lowercased()
            SyncAgentDirectory.shared._setHostsForTesting([.init(device: "studio", name: "Studio", agents: [researcher])])
            defer { SyncAgentDirectory.shared._setHostsForTesting([]) }
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }

            window.switchToHostedAgent(device: "studio", agentId: agentId)
            window.session.turns.append(ChatTurn(role: .user, content: "hosted work"))
            let hostedTab = window.activeTabId
            window.switchAgent(to: Agent.defaultId)
            window.session.turns.append(ChatTurn(role: .user, content: "local work"))
            window.switchToHostedAgent(device: "studio", agentId: agentId)
            #expect(window.activeTabId == hostedTab)
            #expect(window.agentId == Agent.defaultId, "the host's agent isn't one of this Mac's")

            window.newTab()
            #expect(window.activeTabId != hostedTab)
            #expect(window.activeScope == .hosted(device: "studio", agentId: agentId), "a new tab stays with the host's agent")
            #expect(window.agentId == Agent.defaultId)

            window.switchAgent(to: Agent.defaultId)
            window.newTab()
            #expect(window.activeScope == .local(Agent.defaultId), "a new tab from a local chat is local")
            #expect(window.session.hostDevice == nil)
        }
    }

    @Test
    func openingAHostedChatFromHistoryKeepsTheWindowOnTheDefaultAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let agentId = UUID()
            let window = ChatWindowState(windowId: UUID(), agentId: Agent.defaultId)
            defer { window.cleanup() }
            let hosted = ChatSessionData(
                title: "On the studio",
                turns: [ChatTurnData(role: .user, content: "hosted work")],
                agentId: agentId,
                hostDevice: "studio"
            )

            window.loadSession(hosted)
            #expect(window.session.sessionId == hosted.id)
            #expect(window.activeScope == .hosted(device: "studio", agentId: agentId))
            #expect(window.agentId == Agent.defaultId)
        }
    }

    @Test
    func aHostedChatIsItsOwnTabScope() {
        let agentId = UUID()
        let session = ChatSession()
        session.agentId = agentId
        session.hostDevice = "studio"
        #expect(ChatTabScope.of(session) == .hosted(device: "studio", agentId: agentId))
        session.hostDevice = nil
        #expect(ChatTabScope.of(session) != .hosted(device: "studio", agentId: agentId))
    }

    // MARK: - Host

    private func hostedSession(host: String, agentId: UUID?, requestedMs: Int64? = nil) -> ChatSessionData {
        var question = ChatTurnData(role: .user, content: "Summarize the report", createdAt: Date())
        question.hostRun = requestedMs.map { HostRunRequest(device: host, requestedMs: $0) } ?? HostRunRequest(device: host)
        return ChatSessionData(
            id: UUID(),
            title: "Report",
            createdAt: Date(),
            updatedAt: Date(),
            turns: [question],
            agentId: agentId,
            source: .chat,
            hostDevice: host
        )
    }

    private func hostRun(_ session: ChatSessionData, core: SyncCore) -> SyncHostedRunContract.HostRun? {
        guard let scope = SyncConversationStore.shared.scope(forSession: session.id),
            let conversation = try? core.conversation(scope: scope)
        else { return nil }
        return SyncHostedRunContract.read(
            SyncHostedRunContract.HostRun.self,
            SyncHostedRunContract.hostRunNamespace,
            from: conversation
        )
    }

    @Test
    func theHostDeclinesOnceWhenItDoesntRunAgentsForOtherDevices() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let runner = SyncHostRunner.shared
            defer {
                runner._resetForTesting()
                SyncService.shared.close()
            }
            var configuration = SyncConfigurationStore.load()
            configuration.hostAgentsForOtherDevices = false
            SyncConfigurationStore.save(configuration)

            let store = SyncConversationStore.shared
            let session = hostedSession(host: core.deviceKey(), agentId: UUID())
            try store.saveSession(session)
            // The requester's clock says two hours ago; the message itself is new.
            let clockBehind = hostedSession(
                host: core.deviceKey(),
                agentId: UUID(),
                requestedMs: SyncHostedRunContract.nowMs() - 2 * 3_600_000
            )
            try store.saveSession(clockBehind)
            let elsewhere = hostedSession(host: "another-device", agentId: UUID())
            try store.saveSession(elsewhere)

            runner._resetForTesting()
            runner.start()
            try await waitUntil("declined") { (store.loadSession(id: session.id)?.turns.count ?? 0) == 2 }
            let reply = try #require(store.loadSession(id: session.id)?.turns.last)
            #expect(reply.role == .assistant)
            #expect(reply.terminalStopReason == SyncHostedRunContract.declinedStopReason)
            let questionId = session.turns[0].id.uuidString.lowercased()
            try await waitUntil("host-run done") { hostRun(session, core: core)?.state == .done }
            #expect(hostRun(session, core: core)?.turn == questionId)
            #expect(runner._ledgerForTesting().runs[questionId]?.state == .done)

            try await waitUntil("clock-behind request answered") {
                (store.loadSession(id: clockBehind.id)?.turns.count ?? 0) == 2
            }
            #expect(
                store.loadSession(id: clockBehind.id)?.turns.last?.terminalStopReason
                    == SyncHostedRunContract.declinedStopReason)
            #expect(hostRun(elsewhere, core: core) == nil, "another device's chat")

            // The ledger keeps a second look from answering again.
            try store.saveSession(try #require(store.loadSession(id: session.id)))
            try await Task.sleep(for: .milliseconds(600))
            #expect(store.loadSession(id: session.id)?.turns.count == 2)

            // A follow-up while hosting is on, for an agent this Mac doesn't have.
            configuration.hostAgentsForOtherDevices = true
            SyncConfigurationStore.save(configuration)
            var followUp = try #require(store.loadSession(id: session.id))
            var next = ChatTurnData(role: .user, content: "And the appendix?", createdAt: Date())
            next.hostRun = HostRunRequest(device: core.deviceKey())
            followUp.turns.append(next)
            try store.saveSession(followUp)
            try await waitUntil("missing agent declined") { (store.loadSession(id: session.id)?.turns.count ?? 0) == 4 }
            let missing = try #require(store.loadSession(id: session.id)?.turns.last)
            #expect(missing.terminalStopReason == SyncHostedRunContract.declinedStopReason)
            #expect(missing.content.contains("no longer on this Mac"))
        }
    }

    /// A client that writes Swift's `uuidString` as is tags the chat in
    /// uppercase. The host still finds it and answers.
    @Test
    func aChatTaggedWithUppercaseIdsIsStillAnswered() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let runner = SyncHostRunner.shared
            defer {
                runner._resetForTesting()
                SyncService.shared.close()
            }
            var configuration = SyncConfigurationStore.load()
            configuration.hostAgentsForOtherDevices = false
            SyncConfigurationStore.save(configuration)

            let sessionId = UUID()
            let turnId = UUID().uuidString.uppercased()
            let scope = try core.createConversation(title: "Uppercase", replication: .synced)
            let session: [String: Any] = [
                "v": 1, "id": sessionId.uuidString.uppercased(), "source": "chat",
                "agentId": UUID().uuidString.uppercased(), "hostDevice": core.deviceKey(),
            ]
            try core.setConversationAppData(
                scope: scope,
                namespace: SyncConversationMapper.sessionNamespace,
                bytes: JSONSerialization.data(withJSONObject: session)
            )
            try core.setConversationTags(
                scope: scope,
                tags: [
                    Tag(key: SyncConversationMapper.TagKey.session, value: sessionId.uuidString.uppercased()),
                    Tag(key: SyncConversationMapper.TagKey.source, value: "chat"),
                    Tag(key: SyncConversationMapper.TagKey.hostDevice, value: core.deviceKey()),
                ]
            )
            let now = SyncHostedRunContract.nowMs()
            let turn: [String: Any] = [
                "v": 1, "id": turnId, "role": "user", "createdAt": now,
                "hostRun": ["device": core.deviceKey(), "requestedMs": now],
            ]
            _ = try core.sendMessage(
                scope: scope,
                message: OutgoingMessage(
                    role: .user,
                    content: "Summarize the report",
                    attachments: [],
                    replyTo: nil,
                    asAgent: nil,
                    toolCallId: nil,
                    toolName: nil,
                    appData: [
                        AppDataWrite(
                            namespace: SyncConversationMapper.turnNamespace,
                            bytes: try JSONSerialization.data(withJSONObject: turn)
                        )
                    ]
                )
            )

            let store = SyncConversationStore.shared
            store.invalidateCaches()
            runner._resetForTesting()
            runner.start()
            try await waitUntil("declined") { (store.loadSession(id: sessionId)?.turns.count ?? 0) == 2 }
            let reply = try #require(store.loadSession(id: sessionId)?.turns.last)
            #expect(reply.terminalStopReason == SyncHostedRunContract.declinedStopReason)
            #expect(runner._ledgerForTesting().runs[turnId.lowercased()]?.state == .done)
        }
    }

    /// The iPhone's edit and resend (once `POST /sessions/{id}/truncate`):
    /// it deletes the edited turn and what follows, then sends the new text
    /// as a new `hostRun` turn, which the host answers once.
    @Test
    func anEditedAndResentTurnIsAnsweredOnce() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let runner = SyncHostRunner.shared
            defer {
                runner._resetForTesting()
                SyncService.shared.close()
            }
            var configuration = SyncConfigurationStore.load()
            configuration.hostAgentsForOtherDevices = false
            SyncConfigurationStore.save(configuration)

            let store = SyncConversationStore.shared
            let session = hostedSession(host: core.deviceKey(), agentId: UUID())
            try store.saveSession(session)
            runner._resetForTesting()
            runner.start()
            try await waitUntil("first reply") { (store.loadSession(id: session.id)?.turns.count ?? 0) == 2 }

            var edited = try #require(store.loadSession(id: session.id))
            var resent = ChatTurnData(role: .user, content: "Summarize the report in one line", createdAt: Date())
            resent.hostRun = HostRunRequest(device: core.deviceKey())
            edited.turns = [resent]
            try store.saveSession(edited)

            try await waitUntil("reply to the resent turn") {
                let turns = store.loadSession(id: session.id)?.turns ?? []
                return turns.count == 2 && turns[0].id == resent.id && turns[1].role == .assistant
            }
            let scope = try #require(store.scope(forSession: session.id))
            #expect(try core.messages(scope: scope, before: nil, limit: 10).messages.count == 2, "the old turns are gone")
            let ledger = runner._ledgerForTesting().runs
            #expect(ledger[session.turns[0].id.uuidString.lowercased()]?.state == .done)
            #expect(ledger[resent.id.uuidString.lowercased()]?.state == .done)

            try store.saveSession(try #require(store.loadSession(id: session.id)))
            try await Task.sleep(for: .milliseconds(600))
            #expect(store.loadSession(id: session.id)?.turns.count == 2, "answered once")
        }
    }

    /// The directory offers the Default agent too, so a chat with it runs
    /// like one with the user's own agent.
    @Test(arguments: [false, true])
    func theHostAnswersARequestOnceInTheStoredChat(defaultAgent: Bool) async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let runner = SyncHostRunner.shared
            let agent = Agent(name: "Hosted run test", autonomousExec: AutonomousExecConfig(enabled: false))
            if !defaultAgent { AgentManager.shared.add(agent) }
            var configuration = SyncConfigurationStore.load()
            configuration.hostAgentsForOtherDevices = true
            SyncConfigurationStore.save(configuration)

            let store = SyncConversationStore.shared
            let session = hostedSession(host: core.deviceKey(), agentId: defaultAgent ? Agent.defaultId : agent.id)
            try store.saveSession(session)
            let live = ChatSession()
            live.load(from: session)
            live.toolsDisabledForTestingOverride = true
            live.forceChatEngineRouteForTests = true
            live.selectedModel = "hosted-run-test"
            live.chatEngineFactory = { _ in MockChatEngine(deltas: ["The report ", "is short."]) }
            LiveChatSessionRegistry.shared.register(live, id: session.id)
            defer {
                LiveChatSessionRegistry.shared.unregister(id: session.id)
                BackgroundTaskManager.shared.finalizeTask(session.id)
                runner._resetForTesting()
                SyncService.shared.close()
            }

            runner._resetForTesting()
            runner.start()
            let questionId = session.turns[0].id.uuidString.lowercased()
            try await waitUntil("host-run done", timeout: 30) { hostRun(session, core: core)?.state == .done }
            try await waitUntil("answer stored") {
                store.loadSession(id: session.id)?.turns.last?.content == "The report is short."
            }
            let stored = try #require(store.loadSession(id: session.id))
            #expect(stored.turns.map(\.role) == [.user, .assistant])
            #expect(stored.turns.last?.terminalStopReason != SyncHostedRunContract.declinedStopReason)
            #expect(runner._ledgerForTesting().runs[questionId]?.state == .done)

            // Seen again, the request isn't run twice.
            try store.saveSession(stored)
            try await Task.sleep(for: .milliseconds(600))
            #expect(store.loadSession(id: session.id)?.turns.count == 2)
            if !defaultAgent { _ = await AgentManager.shared.delete(id: agent.id) }
        }
    }

    /// Streams one delta, then waits until the run is cancelled.
    private struct UnfinishedEngine: ChatEngineProtocol {
        func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("Working")
                let keepAlive = Task {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in keepAlive.cancel() }
            }
        }

        func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
            try await MockChatEngine().completeChat(request: request)
        }
    }

    @Test
    func aStopFromTheCallerEndsTheRunningRun() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let runner = SyncHostRunner.shared
            let agent = Agent(name: "Hosted stop test", autonomousExec: AutonomousExecConfig(enabled: false))
            AgentManager.shared.add(agent)
            var configuration = SyncConfigurationStore.load()
            configuration.hostAgentsForOtherDevices = true
            SyncConfigurationStore.save(configuration)

            let store = SyncConversationStore.shared
            let session = hostedSession(host: core.deviceKey(), agentId: agent.id)
            try store.saveSession(session)
            let live = ChatSession()
            live.load(from: session)
            live.toolsDisabledForTestingOverride = true
            live.forceChatEngineRouteForTests = true
            live.selectedModel = "hosted-run-test"
            live.chatEngineFactory = { _ in UnfinishedEngine() }
            LiveChatSessionRegistry.shared.register(live, id: session.id)
            defer {
                LiveChatSessionRegistry.shared.unregister(id: session.id)
                BackgroundTaskManager.shared.finalizeTask(session.id)
                runner._resetForTesting()
                SyncService.shared.close()
            }

            runner._resetForTesting()
            runner.start()
            let questionId = session.turns[0].id.uuidString.lowercased()
            try await waitUntil("running", timeout: 30) { hostRun(session, core: core)?.state == .running }
            try await waitUntil("streaming") { live.isStreaming }

            let scope = try #require(store.scope(forSession: session.id))
            let stop = SyncHostedRunContract.RunControl(stop: questionId, stopMs: SyncHostedRunContract.nowMs())
            try store.performWrite { core in
                try core.setConversationAppData(
                    scope: scope,
                    namespace: SyncHostedRunContract.runNamespace,
                    bytes: try SyncHostedRunContract.encode(stop)
                )
            }
            try await waitUntil("host-run done after the stop") { hostRun(session, core: core)?.state == .done }
            #expect(!live.isStreaming)
            #expect(runner._ledgerForTesting().runs[questionId]?.state == .done)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test
    func continuingAMissingSessionIsRefused() async throws {
        try await ChatHistoryTestStorage.run {
            _ = try SyncService.shared.open()
            defer { SyncService.shared.close() }
            let handle = await BackgroundTaskManager.shared.dispatchChat(
                DispatchRequest(prompt: "", showToast: false, continueSessionId: UUID())
            )
            #expect(handle == nil)
        }
    }
}

// Held prompts live in the process-wide prompt state that the queue suite
// resets, so this joins that serialized suite.
extension ToolPermissionPromptQueueTests {
    @Test("a hosted run's prompt waits for the device the user chats on")
    @MainActor
    func aHostedRunsPromptWaitsForTheChattingDevice() async throws {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let presented = OSAllocatedUnfairLock(initialState: [String]())
        let scope = "scope-\(UUID().uuidString)"
        let request = { (tool: String) in
            Task { @MainActor in
                await ToolPermissionPromptService.$presentationOverrideForTests.withValue({ _, name, _ in
                    presented.withLock { $0.append(name) }
                }) {
                    await ChatExecutionContext.$syncReviewerScope.withValue(scope) {
                        await ToolPermissionPromptService.requestApprovalOutcome(
                            toolName: tool,
                            description: "Run a shell command",
                            argumentsJSON: #"{"cmd":"ls"}"#
                        )
                    }
                }
            }
        }
        func waitForHeldPrompt() async throws {
            let deadline = Date().addingTimeInterval(20)
            while ToolPermissionPromptService.syncedPrompts(scope: scope).isEmpty {
                guard Date() < deadline else {
                    Issue.record("timed out waiting for a held prompt")
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        let first = request("sandbox_exec")
        try await waitForHeldPrompt()
        let held = try #require(ToolPermissionPromptService.syncedPrompts(scope: scope).first)
        #expect(held.toolName == "sandbox_exec")
        #expect(held.argumentsJSON == #"{"cmd":"ls"}"#)
        #expect(held.offersRunLease)
        #expect(!ToolPermissionPromptService.resolveFromSyncedDevice(id: held.id, scope: "elsewhere", outcome: .allowOnce))
        #expect(ToolPermissionPromptService.resolveFromSyncedDevice(id: held.id, scope: scope, outcome: .allowForRun))
        #expect(await first.value == .allowForRun)
        #expect(ToolPermissionPromptService.syncedPrompts(scope: scope).isEmpty)

        let second = request("file_write")
        try await waitForHeldPrompt()
        ToolPermissionPromptService.denySyncedPrompts(scope: scope)
        #expect(await second.value == .denied)
        #expect(presented.withLock { $0 }.isEmpty, "no panel on the host")
    }

    @Test("a caller-owned grant answered on the chatting device is committed before the run resumes")
    @MainActor
    func aSyncedAnswerCommitsTheCallerOwnedGrant() async throws {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let scope = "scope-\(UUID().uuidString)"
        let request = {
            Task { @MainActor in
                await ToolPermissionPromptService.$presentationOverrideForTests.withValue({ _, name, _ in
                    events.withLock { $0.append("presented \(name)") }
                }) {
                    await ChatExecutionContext.$syncReviewerScope.withValue(scope) {
                        let outcome = await ToolPermissionPromptService.requestPolicyApprovalOutcome(
                            toolName: "image",
                            description: "Generate an image",
                            argumentsJSON: #"{"prompt":"fox"}"#,
                            offersRunLease: true,
                            commitApproval: { outcome in events.withLock { $0.append("commit \(outcome)") } }
                        )
                        events.withLock { $0.append("resumed \(outcome)") }
                        return outcome
                    }
                }
            }
        }
        func heldPrompt() async throws -> ToolPermissionPromptService.SyncedPrompt {
            let deadline = Date().addingTimeInterval(20)
            while ToolPermissionPromptService.syncedPrompts(scope: scope).isEmpty {
                guard Date() < deadline else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(50))
            }
            return try #require(ToolPermissionPromptService.syncedPrompts(scope: scope).first)
        }

        let approved = request()
        let held = try await heldPrompt()
        #expect(held.offersRunLease)
        #expect(ToolPermissionPromptService.resolveFromSyncedDevice(id: held.id, scope: scope, outcome: .alwaysAllow))
        #expect(await approved.value == .alwaysAllow)
        #expect(events.withLock { $0 } == ["commit alwaysAllow", "resumed alwaysAllow"])

        events.withLock { $0.removeAll() }
        let denied = request()
        _ = try await heldPrompt()
        ToolPermissionPromptService.denySyncedPrompts(scope: scope)
        #expect(await denied.value == .denied)
        #expect(events.withLock { $0 } == ["resumed denied"])
    }
}
