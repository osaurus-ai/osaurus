//
//  SyncAppDataFixtureTests.swift
//  OsaurusCoreTests
//
//  The app data contract's test vectors (copied from osaurus-sync's
//  tests/fixtures/app-data) read into the sessions they describe, and
//  fields this version doesn't know survive a rewrite.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct SyncAppDataFixtureTests {
    /// Imports a fixture the way another client would have written it.
    private func importFixture(_ name: String, into core: SyncCore) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "SyncFixtures"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let conversation = try #require(root["conversation"] as? [String: Any])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func file(_ entry: [String: Any]) throws -> AttachmentFile {
            let name = entry["name"] as? String ?? "file"
            let path = directory.appendingPathComponent(UUID().uuidString + "-" + name)
            try Data((entry["text"] as? String ?? "").utf8).write(to: path)
            return AttachmentFile(path: path.path, mediaType: entry["media_type"] as? String ?? "", name: name)
        }
        func bytes(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }

        let tags = ((conversation["tags"] as? [String: String]) ?? [:]).map { Tag(key: $0.key, value: $0.value) }
        let appData = try ((conversation["app_data"] as? [String: Any]) ?? [:]).map {
            AppDataEntry(namespace: $0.key, bytes: try bytes($0.value))
        }
        let roles: [String: OsaurusSync.MessageRole] = [
            "user": .user, "assistant": .assistant, "system": .system, "tool_result": .toolResult,
        ]
        let messages = try ((root["messages"] as? [[String: Any]]) ?? []).map { message -> LegacyMessage in
            let blobs = (message["app_data_blobs"] as? [String: [[String: Any]]]) ?? [:]
            let writes = try ((message["app_data"] as? [String: Any]) ?? [:]).map { namespace, value in
                AppDataWrite(namespace: namespace, bytes: try bytes(value), attachments: try (blobs[namespace] ?? []).map(file))
            }
            return LegacyMessage(
                role: roles[message["role"] as? String ?? ""] ?? .user,
                content: message["content"] as? String ?? "",
                createdMs: (message["created_ms"] as? NSNumber)?.uint64Value ?? 0,
                attachments: try ((message["attachments"] as? [[String: Any]]) ?? []).map(file),
                toolCallId: message["tool_call_id"] as? String,
                toolName: message["tool_name"] as? String,
                appData: writes
            )
        }
        return try core.importLegacyConversation(
            conversation: LegacyConversation(
                title: conversation["title"] as? String ?? "",
                createdMs: (conversation["created_ms"] as? NSNumber)?.uint64Value ?? 0,
                replication: .synced,
                pinned: conversation["pinned"] as? Bool ?? false,
                archived: conversation["archived"] as? Bool ?? false,
                tags: tags,
                appData: appData
            ),
            messages: messages
        )
    }

    @Test
    func fullFixtureReadsIntoASession() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let store = SyncConversationStore.shared
            _ = try importFixture("full", into: core)

            let id = try #require(UUID(uuidString: "0b3e5c1d-2f4a-4b6c-9d8e-1f2a3b4c5d6e"))
            let session = try #require(store.loadSession(id: id))
            #expect(session.title == "Weather in Lisbon")
            #expect(session.pinned)
            #expect(session.source == .chat)
            #expect(session.agentId == UUID(uuidString: "c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f"))
            #expect(session.projectId == UUID(uuidString: "d4c3b2a1-0f9e-4d8c-b7a6-5f4e3d2c1b0a"))
            #expect(session.selectedModel == "OsaurusAI/gemma-4-qat-mxfp4")
            #expect(session.capabilities == [.search, .vision])
            #expect(session.conversationSummary?.summaryText == "The user is planning a trip to Lisbon.")
            #expect(session.parkedWorkflowRuns.first?.toolName == "run_workflow")
            #expect(session.createdAt == Date(timeIntervalSince1970: 1_767_225_600))

            #expect(session.turns.map(\.role) == [.user, .assistant, .tool, .assistant])
            let user = session.turns[0]
            #expect(user.id == UUID(uuidString: "b0000000-0000-4000-8000-000000000001"))
            #expect(user.injectedContextPrefix == "<memory>The user prefers Celsius.</memory>")
            #expect(user.attachments.first?.filename == "itinerary.txt")
            #expect(user.attachments.first?.loadDocumentContent() == "Day 1: Alfama. Day 2: Belém.")
            #expect(session.turns[1].thinking == "The user wants current weather; call the weather tool.")
            #expect(session.turns[1].toolCalls?.first?.function.name == "get_weather")
            #expect(session.turns[2].toolCallId == "call_1")
            #expect(session.turns[2].toolCallDurations == ["call_1": 0.42])
            let answer = session.turns[3]
            #expect(answer.content == "It's 21°C and clear in Lisbon.")
            #expect(answer.generationTokenCount == 12)
            #expect(answer.cachedInputTokenCount == 256)
            #expect(answer.terminalStopReason == "stop")
            #expect(answer.completedAt == Date(timeIntervalSince1970: 1_767_225_606))
            #expect(answer.routerBilling != nil)
        }
    }

    @Test
    func hostedFixtureReadsItsHostAndRunRequests() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let store = SyncConversationStore.shared
            _ = try importFixture("hosted", into: core)

            let host = "7c1f0e2d9a8b4c3d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5"
            let id = try #require(UUID(uuidString: "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b"))
            var session = try #require(store.loadSession(id: id))
            #expect(session.hostDevice == host)
            #expect(session.agentId == UUID(uuidString: "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"))
            #expect(session.turns.map(\.role) == [.user, .assistant, .user])
            #expect(session.turns[0].hostRun == HostRunRequest(device: host, requestedMs: 1_767_398_400_000))
            #expect(session.turns[1].hostRun == nil)
            #expect(session.turns[2].hostRun?.device == host)

            session.title = "Renamed"
            try store.saveSession(session)
            store.invalidateCaches()
            let reread = try #require(store.loadSession(id: id))
            #expect(reread.hostDevice == host)
            #expect(reread.turns[2].hostRun?.requestedMs == 1_767_398_450_000)
        }
    }

    @Test
    func servedFixtureReadsItsServerAuthorsAndApprovals() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let store = SyncConversationStore.shared
            let scope = try importFixture("served", into: core)

            let server = "7c1f0e2d9a8b4c3d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5"
            let answerer = "3b9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f"
            let id = try #require(UUID(uuidString: "6a7b8c9d-0e1f-4a2b-8c3d-4e5f6a7b8c9d"))
            let session = try #require(store.loadSession(id: id))
            #expect(session.source == .workspace)
            #expect(session.servedBy == server)
            #expect(session.hostDevice == nil)
            #expect(session.workspace?.callerHandle == "alice")
            #expect(session.turns.map { $0.author?.kind } == [.teammate, nil, .ownerDevice])
            #expect(session.turns[2].author?.deviceLabel == "MacBook Air")

            let conversation = try #require(try core.conversation(scope: scope))
            typealias Contract = SyncServedChatsContract
            let delivery = Contract.read(Contract.Delivery.self, Contract.deliveryNamespace, from: conversation)
            #expect(delivery?.delivered == ["f0000000-0000-4000-8000-000000000003"])
            let pending = try #require(
                Contract.read(Contract.Approvals.self, Contract.approvalNamespace, from: conversation)?.pending.first)
            #expect(pending.tool == "file_write")
            #expect(pending.arguments == #"{"path":"RELEASE_NOTES.md"}"#)
            #expect(pending.expiresMs == 1_767_485_460_000)
            let answers = Contract.answers(in: conversation)
            #expect(answers.keys.sorted() == [answerer])
            #expect(answers[answerer]?.answers[pending.id] == Contract.AnswerEntry(answer: .approved, answeredMs: 1_767_484_870_000))
            let decisions = Contract.firstAnswers(answers, deviceNames: [answerer: "MacBook Air"])
            #expect(decisions.map(\.id) == [pending.id])
            #expect(Contract.firstAnswers(answers, deviceNames: [:]).isEmpty, "not one of the user's devices")
        }
    }

    @Test
    func anUnreadableFieldDropsOnlyThatField() throws {
        let object: JSONObject = [
            "id": "0b3e5c1d-2f4a-4b6c-9d8e-1f2a3b4c5d6e", "title": "T", "createdAt": 1_767_225_600_000,
            "updatedAt": 1_767_225_600_000, "turns": [Any](), "archived": false, "pinned": true, "source": "chat",
            "selectedModel": "m", "conversationSummary": ["summaryText": "no other fields"],
        ]
        let session = try #require(
            SyncConversationMapper.decodeTolerantly(
                ChatSessionData.self, from: object, keeping: SyncConversationMapper.sessionRequiredKeys))
        #expect(session.selectedModel == "m")
        #expect(session.pinned)
        #expect(session.conversationSummary == nil)
    }

    @Test
    func minimalFixtureReads() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let scope = try importFixture("minimal", into: core)
            let conversation = try #require(try core.conversation(scope: scope))
            let id = SyncConversationMapper.sessionId(of: conversation)
            let session = try #require(SyncConversationStore.shared.loadSession(id: id))
            #expect(!session.turns.isEmpty)
            #expect(session.turns.allSatisfy { !$0.content.isEmpty || $0.role == .assistant })
        }
    }

    @Test
    func unknownFieldsSurviveARewrite() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let store = SyncConversationStore.shared
            let scope = try importFixture("future", into: core)
            let id = try #require(UUID(uuidString: "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"))

            var session = try #require(store.loadSession(id: id))
            #expect(session.archived)
            #expect(session.source == .imported)
            #expect(session.turns.first?.toolResults["call_9"] == "a very long tool result")

            session.title = "Renamed"
            session.turns[0].thinking = "Now with thinking."
            try store.saveSession(session)

            let conversation = try #require(try core.conversation(scope: scope))
            #expect(conversation.title == "Renamed")
            #expect(conversation.tag("futureTag") == "kept")
            let sessionObject = try #require(
                SyncConversationMapper.parseObject(conversation.appData("ai.osaurus.session/1")))
            #expect(sessionObject["futureSessionField"] != nil)
            #expect(conversation.appData("ai.osaurus.session.future/1") != nil)

            let message = try #require(try core.messages(scope: scope, before: nil, limit: 10).messages.first)
            let turnObject = try #require(SyncConversationMapper.parseObject(message.appData("ai.osaurus.turn/1")?.bytes))
            #expect(turnObject["futureTurnField"] as? String == "kept")
            #expect(turnObject["thinking"] as? String == "Now with thinking.")
            #expect(message.appData("ai.osaurus.turn.future/1") != nil)

            store.invalidateCaches()
            #expect(store.loadSession(id: id)?.turns.first?.toolResults["call_9"] == "a very long tool result")
        }
    }

    // MARK: - iPhone over Sync (docs/SYNC_MOBILE_CONTRACT.md v2)

    private let mac = "7c1f0e2d9a8b4c3d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5"
    private let phone = "3b9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f"
    private let secondPhone = "4c0e5f6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f80"

    private func object(_ data: Data?) throws -> [String: Any] {
        try #require(SyncConversationMapper.parseObject(try #require(data)))
    }

    private func keys(_ value: Any?) -> Set<String> {
        Set((value as? [String: Any])?.keys.map { $0 } ?? [])
    }

    private func allMessages(_ core: SyncCore, scope: String) throws -> [SyncMessage] {
        try core.messages(scope: scope, before: nil, limit: 50).messages
    }

    @Test
    func mobileHostedFixtureCarriesTheRunOptionsAndTheHostsRecords() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let scope = try importFixture("mobile-hosted", into: core)
            let id = try #require(UUID(uuidString: "8b9c0d1e-2f3a-4b4c-8d5e-6f7a8b9c0d1e"))
            let session = try #require(SyncConversationStore.shared.loadSession(id: id))
            #expect(session.hostDevice == mac)
            #expect(session.turns.map(\.role) == [.user, .assistant, .tool, .assistant, .user])

            let chat = try #require(session.turns[0].hostRun)
            #expect(
                chat
                    == HostRunRequest(
                        device: mac, requestedMs: 1_767_571_200_000, model: "OsaurusAI/gemma-4-qat-mxfp4",
                        options: .init(reasoningEffort: "low", thinking: false),
                        voiceCall: .init(instructions: "Answer in two short spoken sentences."), privacy: "auto"))
            #expect(chat.generationOverrides == ChatTurnOverrides(reasoningEffort: "low", enableThinking: false))
            #expect(
                session.turns[4].hostRun?.image
                    == .init(seed: 7, negativePrompt: "text, watermark", aspectRatio: "16:9", quality: "high", count: 1))

            let conversation = try #require(try core.conversation(scope: scope))
            let progress = try JSONDecoder().decode(
                SyncRunProgressContract.Progress.self,
                from: try #require(conversation.appData(SyncRunProgressContract.namespace)))
            #expect(progress.turn == "f1000000-0000-4000-8000-000000000005")
            #expect(progress.phase == .image)
            #expect(progress.image == .init(step: 3, total: 4))
            #expect(progress.prefill == .init(stage: "prefill", done: 2048, total: 2048))
            #expect(progress.tools.map(\.state) == [.done, .preparing])
            #expect(progress.tools[1].id == SyncRunProgressContract.preparingToolId)
            #expect(progress.artifacts.first?.filename == "outline.md")

            let usage = try object(conversation.appData(SyncContextUsage.namespace))
            #expect(keys(usage) == ["v", "usage", "agentId", "model", "updatedMs"])
            #expect(
                keys(usage["usage"]).isSuperset(of: ["tokens", "near_limit", "hard_overflow", "context", "messages"]))

            let approval = try #require(
                SyncHostedRunContract.read(
                    SyncHostedRunContract.Approvals.self, SyncHostedRunContract.approvalNamespace, from: conversation
                )?.pending.first)
            #expect(approval.tool == "image")
            #expect(approval.surface == nil)
            let arguments = try #require(
                try JSONSerialization.jsonObject(with: Data(approval.arguments.utf8)) as? [String: Any])
            #expect(arguments["billing_notice"] != nil && arguments["estimated_minimum_usd"] != nil)

            let messages = try allMessages(core, scope: scope)
            let detailNamespace = SyncConversationMapper.turnDetailNamespace
            let withDetail = messages.filter { $0.appData(detailNamespace) != nil }
            #expect(withDetail.count == 2)
            let labels = try object(withDetail.first { $0.content.isEmpty }?.appData(detailNamespace)?.bytes)
            let fixtureLabel = (labels["toolCallDisplay"] as? [String: Any])?["call_7"]
            let macLabel = SyncConversationMapper.toolCallDisplay(for: session.turns[1])?["call_7"]
            #expect(keys(fixtureLabel) == keys(macLabel), "the labels the Mac writes")
            let reply = try #require(withDetail.first { !$0.content.isEmpty }?.appData(detailNamespace))
            #expect(reply.blobs.count == 1)
            let files = try #require(try object(reply.bytes)["files"] as? [[String: Any]])
            #expect(files.map { $0["kind"] as? String } == ["generatedImage", "artifact"])
            #expect((files[0]["blob"] as? NSNumber)?.intValue == 0)
            #expect(files[1]["skipped"] as? String == "tooLarge" && files[1]["blob"] == nil)
        }
    }

    @Test
    func mobileWorkspaceFixtureRunsTowardTheSharedAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            _ = try importFixture("mobile-workspace", into: core)
            let id = try #require(UUID(uuidString: "9c0d1e2f-3a4b-4c5d-8e6f-7a8b9c0d1e2f"))
            let session = try #require(SyncConversationStore.shared.loadSession(id: id))
            #expect(session.hostDevice == mac)
            #expect(session.agentId == nil)
            #expect(session.isWorkspaceAgentChat)
            #expect(session.turns.first?.hostRun?.privacy == "off")
            let ref = WorkspaceAgentRef(workspaceId: "ws_3f2a", agentAddress: "0x" + String(repeating: "ab", count: 20))
            #expect(try SyncHostRunner.workspaceTarget(for: session, listed: [ref.key]).get() == ref)
        }
    }

    @Test
    func mobileDirectoryFixtureListsWhatThisBuildSupports() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let scope = try importFixture("mobile-directory", into: core)
            let conversation = try #require(try core.conversation(scope: scope))
            let directory = try #require(
                SyncHostedRunContract.read(
                    SyncHostedRunContract.Directory.self, SyncHostedRunContract.directoryNamespace, from: conversation))
            #expect(directory.device == mac)
            #expect(directory.features == SyncDeviceFeedContract.features, "update the fixture with the feature list")
            #expect(directory.build == "0.25.31 (1234)")
            #expect(directory.presence == .init(state: .sleeping, networkMode: "anywhere", updatedMs: 1_767_574_600_000))
            #expect(directory.agents.first?.isDefault == true)
        }
    }

    @Test
    func mobileAttentionFixtureReadsEachIPhonesAnswersAndTheMacsDetail() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let scope = try importFixture("mobile-attention", into: core)
            let conversation = try #require(try core.conversation(scope: scope))

            let answers = SyncAttentionFeed.answers(
                in: conversation, deviceNames: [phone: "Sam's iPhone", secondPhone: "Work iPhone"],
                legacyLabel: "Your iPhone")
            #expect(answers.map(\.deviceLabel) == ["Work iPhone", "Your iPhone", "Sam's iPhone"])
            #expect(answers.map(\.answer.action) == ["approve_rest", "deny", "approve"])
            #expect(answers[2].answer.redact == ["B1000000-0000-4000-8000-000000000001"])
            #expect(SyncDeviceFeedContract.outcome(for: "approve_rest") == .allowedForConversation)
            let known = SyncAttentionFeed.answers(
                in: conversation, deviceNames: [phone: "Sam's iPhone"], legacyLabel: "Your iPhone")
            #expect(known.count == 2, "a device not in the account is skipped")

            let feed = try object(conversation.appData(SyncDeviceFeedContract.attentionNamespace))
            let items = try #require(feed["items"] as? [[String: Any]])
            #expect(items.map { $0["kind"] as? String } == ["computer_use", "config_approval", "privacy_review"])
            for item in items {
                let kind = try #require(AttentionKind(rawValue: item["kind"] as? String ?? ""))
                #expect(kind.isBlocking)
                #expect(item["detail"] is [String: Any])
            }

            let preview = ActionPreview(
                appName: "Mail", actionLabel: "Click", targetLabel: "Send", effect: .consequential, note: nil,
                typedText: String(repeating: "a", count: ComputerUsePromptQueue.typedTextDetailLimit + 1))
            var computerUse = AttentionProducers.item(
                id: UUID(), kind: .computerUse, title: "Click Send in Mail?", body: "b",
                actions: [.approve, .approveRest, .deny, .open])
            computerUse.detail = ComputerUsePromptQueue.detail(for: preview)
            computerUse.sessionId = UUID()
            computerUse.agentId = UUID()
            let wire = PairedDeviceChannel.wire(computerUse)
            #expect(keys(wire) == keys(items[0]), "the item fields the Mac writes")
            #expect(keys(wire["detail"]) == keys(items[0]["detail"]), "the Computer Use detail the Mac writes")
            #expect(items[0]["actions"] as? [String] == computerUse.actions.map(\.rawValue))

            #expect(keys(items[1]["detail"]) == ["change_count", "actions", "prune"])
            #expect(
                items[2]["actions"] as? [String] == AttentionItem.defaultActions(for: .privacyReview).map(\.rawValue))
            let rows = try #require((items[2]["detail"] as? [String: Any])?["items"] as? [[String: Any]])
            #expect(rows.allSatisfy { keys($0) == ["id", "category", "original", "placeholder"] })

            let recent = try #require((feed["recent"] as? [[String: Any]])?.first)
            #expect(recent["detail"] == nil && recent["arguments_preview"] == nil, "settled items carry neither")
        }
    }

    @Test
    func mobileManageFixtureReadsTheNewOpsResultsAndDetailMessages() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            let scope = try importFixture("mobile-manage", into: core)
            let conversation = try #require(try core.conversation(scope: scope))
            typealias Feed = SyncDeviceFeedContract

            let requests = try #require(
                Feed.perDevice(Feed.ManageRequests.self, prefix: Feed.manageRequestNamespacePrefix, in: conversation)[
                    phone]
            ).requests
            #expect(
                requests.map(\.op) == [
                    .setFavorite, .getModelOptions, .setModelOption, .setModelOption, .setTool, .warm, .contextUsage,
                    .unsupported,
                ])
            #expect(requests[2].value == .bool(false))
            #expect(requests[3].clearValue == true && requests[3].value == nil)
            #expect(requests[4].policy == "ask" && requests[4].agentEnabled == true && requests[4].enabled == nil)

            let unsupported = await SyncManageFeed.perform(requests[7])
            let results = try #require(
                Feed.perDevice(Feed.ManageResults.self, prefix: Feed.manageResultNamespacePrefix, in: conversation)[phone]
            ).results
            #expect(results["r17"]?.error == unsupported.error && results["r17"]?.message == unsupported.message)
            #expect(results["r10"]?.data == .object(["favorites": .array([.string("local:OsaurusAI/gemma-4-qat-mxfp4")])]))
            #expect(results["r15"]?.data == .object(["loaded": .bool(true), "already": .bool(false)]))

            let state = try #require(
                SyncHostedRunContract.read(Feed.ManageState.self, Feed.manageStateNamespace, from: conversation))
            #expect(
                state.workspaceAgents == [
                    .init(
                        workspaceId: "ws_3f2a", workspaceName: "Studio", address: "0x" + String(repeating: "ab", count: 20),
                        name: "Researcher", ownerName: "Sam")
                ])
            let filters = SyncManageFeed.HistoryFilters(
                projects: [.init(id: "D4C3B2A1-0F9E-4D8C-B7A6-5F4E3D2C1B0A", name: "Launch")],
                plugins: [.init(id: "osaurus.time", name: "Time")],
                workspaces: [.init(id: "ws_3f2a", name: "Studio")])
            let written = SyncManageFeed.state(device: mac, agents: [], models: [], filters: filters)
            #expect(state.projects == written.projects && state.plugins == written.plugins)
            #expect(state.workspaces == written.workspaces)

            let messages = try allMessages(core, scope: scope)
            let models = try #require(messages.first { $0.appData(Feed.manageModelsNamespace) != nil })
            #expect(models.content == Feed.modelsMessageContent)
            let modelsObject = try object(models.appData(Feed.manageModelsNamespace)?.bytes)
            let macModels = try object(SyncManageDetail.modelsPayload(models: [], favorites: [])?.object)
            #expect(keys(modelsObject) == keys(macModels))
            let row = try #require((modelsObject["models"] as? [[String: Any]])?.first)
            #expect(
                keys(row).isSuperset(of: [
                    "id", "name", "provider", "source", "vision", "thinking", "available", "tab", "tab_title",
                    "favorite_key", "kind", "edits",
                ]))

            let agent = try #require(messages.first { $0.appData(Feed.agentDetailNamespace) != nil })
            #expect(agent.content == Feed.agentDetailMessageContent)
            let detail = try #require(agent.appData(Feed.agentDetailNamespace))
            #expect(detail.blobs.count == 2)
            let key = try #require(SyncManageDetail.detailKey(of: agent))
            #expect(key.0 == "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d" && key.1 == "9a1e")
            let agentObject = try object(detail.bytes)
            #expect(SyncConversationMapper.isBlobReference(agentObject["systemPrompt"] as Any))

            let tool = HTTPHandler.AgentToolDTO(
                name: "web_fetch", description: "Fetch a web page.", enabled: true, policy: "ask", remote_safe: false,
                blocked_by: nil, built_in: false, agent_enabled: true)
            let macAgent = try object(
                SyncManageDetail.agentPayload(
                    Agent(
                        name: "Writer",
                        systemPrompt: String(repeating: "x", count: SyncManageDetail.inlineLimit + 1),
                        chatQuickActions: [.init(icon: "pencil", text: "Draft a post", prompt: "Draft a post about ")]
                    ),
                    tools: [tool]
                )?.object)
            #expect(keys(macAgent).union(["avatarImage"]) == keys(agentObject), "the detail the Mac writes")
            let tools = try #require(agentObject["tools"] as? [[String: Any]])
            let macTool = try #require(
                try JSONSerialization.jsonObject(with: JSONEncoder.osaurusCanonical().encode(tool)) as? [String: Any])
            #expect(keys(tools[0]) == keys(macTool))
            #expect(keys(tools[1]) == keys(macTool).union(["blocked_by"]))
        }
    }
}
