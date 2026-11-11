//
//  SyncMobileV2Tests.swift
//  OsaurusCoreTests
//
//  The records docs/SYNC_MOBILE_CONTRACT.md v2 adds for the iPhone: answers
//  and requests per iPhone, the directory's features and presence, run
//  options on hostRun, run progress, models, agent detail, attention detail
//  and the new management ops.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite("Mobile Sync protocol v2", .serialized)
@MainActor
struct SyncMobileV2Tests {
    private func device(_ id: String, _ name: String, _ platform: String = "ios", revoked: Bool = false) -> Device {
        Device(id: id, user: "u", name: name, platform: platform, lastSeenMs: nil, revoked: revoked, isSelf: false)
    }

    private func appData<T: Encodable>(_ namespace: String, _ value: T) throws -> AppDataEntry {
        AppDataEntry(namespace: namespace, bytes: try SyncHostedRunContract.encode(value))
    }

    private func conversation(_ entries: [AppDataEntry]) -> Conversation {
        Conversation(
            scope: "scope", kind: .conversation, title: "t", pinned: false, sortOrder: nil, archived: false,
            lastActivityHlc: 0, lastPreview: nil, unread: 0, myRole: nil, members: [], replication: .synced,
            createdMs: 0, messageCount: 0, tags: [], appData: entries)
    }

    // MARK: - Answers per iPhone

    @Test func eachIPhoneAnswersInItsOwnNamespaceAndTheEarliestWins() throws {
        let now = SyncHostedRunContract.nowMs()
        let work = SyncDeviceFeedContract.AttentionAnswers(answers: [
            "a": .init(action: "deny", answeredMs: now - 10)
        ])
        let personal = SyncDeviceFeedContract.AttentionAnswers(answers: [
            "a": .init(action: "approve", answeredMs: now - 20),
            "b": .init(action: "approve", answeredMs: now),
        ])
        let stranger = SyncDeviceFeedContract.AttentionAnswers(answers: [
            "c": .init(action: "approve", answeredMs: now)
        ])
        let legacy = SyncDeviceFeedContract.AttentionAnswers(answers: [
            "d": .init(action: "approve", answeredMs: now - 5)
        ])
        let stored = conversation([
            try appData(SyncDeviceFeedContract.attentionAnswerNamespace(device: "p1"), personal),
            try appData(SyncDeviceFeedContract.attentionAnswerNamespace(device: "p2"), work),
            try appData(SyncDeviceFeedContract.attentionAnswerNamespace(device: "gone"), stranger),
            try appData(SyncDeviceFeedContract.attentionAnswerNamespace, legacy),
        ])
        let names = SyncDeviceFeedContract.deviceNames([
            device("p1", "Tae's iPhone"), device("p2", "Work iPhone"), device("gone", "Old", revoked: true),
        ])
        let entries = SyncAttentionFeed.answers(in: stored, deviceNames: names, legacyLabel: "Your iPhone")
        #expect(entries.map(\.id) == ["a", "a", "d", "b"])
        #expect(entries.first?.deviceLabel == "Tae's iPhone")
        #expect(entries.first(where: { $0.id == "d" })?.deviceLabel == "Your iPhone")
        #expect(!entries.contains { $0.id == "c" })

        let center = AttentionCenter(channels: [])
        var settled: [AttentionResolution] = []
        let id = center.raise(AttentionItem(kind: .toolApproval, title: "Allow?")) { settled.append($0) }
        typealias Entry = SyncAttentionFeed.LabeledAnswer
        var applied: Set<String> = []
        SyncAttentionFeed.apply(
            [
                Entry(id: id.uuidString, answer: .init(action: "approve", answeredMs: now - 20), deviceLabel: "Tae's iPhone"),
                Entry(id: id.uuidString, answer: .init(action: "deny", answeredMs: now - 10), deviceLabel: "Work iPhone"),
            ],
            applied: &applied, center: center, nowMs: now)
        #expect(settled.map(\.outcome) == [.approved])
        #expect(settled.first?.decidedBy == .ownerDevice("Tae's iPhone"))
    }

    @Test func twoIPhonesRequestsWithTheSameIdBothRunOnce() async throws {
        let now = SyncHostedRunContract.nowMs()
        let one = SyncDeviceFeedContract.ManageRequests(requests: [.init(id: "r1", op: .createAgent, name: "A", requestedMs: now)])
        let two = SyncDeviceFeedContract.ManageRequests(requests: [.init(id: "r1", op: .createAgent, name: "B", requestedMs: now)])
        let stored = conversation([
            try appData(SyncDeviceFeedContract.manageRequestNamespace(device: "p1"), one),
            try appData(SyncDeviceFeedContract.manageRequestNamespace(device: "p2"), two),
            try appData(SyncDeviceFeedContract.manageRequestNamespace(device: "stranger"), two),
        ])
        let sources = SyncManageFeed.sources(
            in: stored, deviceNames: ["p1": "One", "p2": "Two"])
        #expect(sources.map(\.device) == ["p1", "p2"])
        #expect(sources.map(\.resultNamespace) == [
            SyncDeviceFeedContract.manageResultNamespace(device: "p1"),
            SyncDeviceFeedContract.manageResultNamespace(device: "p2"),
        ])

        var ledger = SyncManageFeed.Ledger()
        var names: [String] = []
        for source in sources {
            let outcome = await SyncManageFeed.apply(
                source: source, ledger: &ledger, nowMs: now, save: { _ in },
                perform: { request in
                    names.append(request.name ?? "")
                    #expect(request.id == "r1")
                    return .init(ok: true, doneMs: now)
                })
            #expect(Array(outcome.results.keys) == ["r1"])
        }
        #expect(names == ["A", "B"])
        #expect(Set(ledger.requests.keys) == ["p1/r1", "p2/r1"])

        // Nothing runs again on a second pass.
        for source in sources {
            let again = await SyncManageFeed.apply(
                source: source, ledger: &ledger, nowMs: now + 1, save: { _ in },
                perform: { _ in
                    Issue.record("ran twice")
                    return .init(ok: true, doneMs: now)
                })
            #expect(again.applied == 0)
        }
    }

    // MARK: - Directory

    @Test func theDirectoryCarriesFeaturesBuildAndPresence() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            defer { SyncService.shared.close() }
            let entry = SyncHostedRunContract.DirectoryEntry(id: UUID().uuidString.lowercased(), name: "Researcher")
            try SyncAgentDirectory.publish([entry], core: core, deviceName: "Studio")
            func stored() throws -> SyncHostedRunContract.Directory {
                let filter = ConversationFilter(tags: [
                    Tag(key: SyncConversationMapper.TagKey.kind, value: SyncHostedRunContract.directoryKind)
                ])
                let found = try #require(try core.conversationsFiltered(filter: filter).first)
                return try #require(
                    SyncHostedRunContract.read(
                        SyncHostedRunContract.Directory.self, SyncHostedRunContract.directoryNamespace, from: found))
            }
            let first = try stored()
            #expect(first.features == SyncDeviceFeedContract.features)
            #expect(first.build?.isEmpty == false)
            #expect(first.presence?.state == .awake)
            #expect(first.presence?.networkMode == "localNetworkOnly")

            SyncAgentDirectory.writePresence(.sleeping, core: core)
            let asleep = try stored()
            #expect(asleep.presence?.state == .sleeping)
            #expect(asleep.agents == [entry])

            // Publishing again on wake says awake.
            try SyncAgentDirectory.publish([entry], core: core, deviceName: "Studio")
            #expect(try stored().presence?.state == .awake)
        }
    }

    // MARK: - Run options

    private let picker = [
        ModelPickerItem(id: "foundation", displayName: "Apple", source: .foundation),
        ModelPickerItem(id: "mlx-community/Qwen3-4B", displayName: "Qwen3 4B", source: .local),
    ]

    @Test func anOwnIPhoneChoosesTheModelOptionsCallNoteAndPrivacy() throws {
        let marker = HostRunRequest(
            device: "mac", requestedMs: 1, model: "mlx-community/Qwen3-4B",
            options: .init(reasoningEffort: "high", thinking: false),
            voiceCall: .init(instructions: "  Keep it short.  "), privacy: "auto")
        let result = try SyncHostRunner.choices(
            for: marker, requester: "p1", me: "mac", devices: [device("p1", "iPhone")], pickerItems: picker
        ).get()
        #expect(result.run?.model == "mlx-community/Qwen3-4B")
        #expect(result.run?.voiceCall == true)
        #expect(result.run?.instructions == "Keep it short.")
        #expect(result.run?.privacy == .auto)
        #expect(result.overrides == ChatTurnOverrides(reasoningEffort: "high", enableThinking: false))
    }

    @Test func choicesFromAnotherAccountOrARevokedDeviceAreIgnored() throws {
        let marker = HostRunRequest(device: "mac", requestedMs: 1, model: "foundation", privacy: "off")
        for (requester, devices) in [("x", [Device]()), ("p1", [device("p1", "Old", revoked: true)])] {
            let result = try SyncHostRunner.choices(
                for: marker, requester: requester, me: "mac", devices: devices, pickerItems: picker
            ).get()
            #expect(result == SyncHostRunner.HostedChoices())
        }
    }

    @Test func onlyTheUsersCurrentDevicesMayAskForARun() {
        let devices = [device("p1", "iPhone"), device("old", "Old", revoked: true)]
        for ownChat in [false, true] {
            #expect(SyncHostRunner.mayRequest("p1", me: "mac", devices: devices, ownChat: ownChat))
            #expect(SyncHostRunner.mayRequest("P1", me: "mac", devices: devices, ownChat: ownChat))
            #expect(!SyncHostRunner.mayRequest("old", me: "mac", devices: devices, ownChat: ownChat))
            #expect(!SyncHostRunner.mayRequest("stranger", me: "mac", devices: devices, ownChat: ownChat))
            #expect(!SyncHostRunner.mayRequest(nil, me: "mac", devices: devices, ownChat: ownChat))
        }
        // A chat this Mac hosts may be continued here; its own chats run locally.
        #expect(SyncHostRunner.mayRequest("mac", me: "mac", devices: devices, ownChat: false))
        #expect(!SyncHostRunner.mayRequest("mac", me: "mac", devices: devices, ownChat: true))
    }

    @Test func aRequestIsLateByTheLaterOfItsClockAndItsHLC() {
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let hour: Int64 = 3_600_000
        func hlc(_ ms: Int64) -> UInt64 { UInt64(ms) << 16 }
        #expect(SyncHostRunner.isStale(requestedMs: nowMs - 2 * hour, messageHlc: hlc(nowMs - 2 * hour), now: now))
        #expect(SyncHostRunner.isStale(requestedMs: nowMs - 2 * hour, messageHlc: nil, now: now))
        // A requester whose clock runs behind still sent it just now.
        #expect(!SyncHostRunner.isStale(requestedMs: nowMs - 2 * hour, messageHlc: hlc(nowMs - 60_000), now: now))
        #expect(!SyncHostRunner.isStale(requestedMs: nowMs - 60_000, messageHlc: nil, now: now))
    }

    @Test func aModelThisMacDoesNotHaveIsDeclined() {
        let marker = HostRunRequest(device: "mac", requestedMs: 1, model: "missing/model")
        let result = SyncHostRunner.choices(
            for: marker, requester: "p1", me: "mac", devices: [device("p1", "iPhone")], pickerItems: picker)
        guard case .failure(let refusal) = result else {
            Issue.record("expected a decline")
            return
        }
        #expect(refusal.message.contains("missing/model"))
    }

    @Test func aBlankEffortIsNoChoice() throws {
        let blank = HostRunRequest(device: "mac", requestedMs: 1, options: .init(reasoningEffort: "  "))
        let none = try SyncHostRunner.choices(
            for: blank, requester: "mac", me: "mac", devices: [], pickerItems: picker
        ).get()
        #expect(none == SyncHostRunner.HostedChoices())
    }

    @Test func anOldHostRunStillDecodesAndANewFieldOfTheWrongTypeIsDropped() throws {
        let old = try JSONDecoder().decode(
            HostRunRequest.self, from: Data(#"{"device":"mac","requestedMs":5}"#.utf8))
        #expect(old == HostRunRequest(device: "mac", requestedMs: 5))
        let encoded = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        #expect(!encoded.contains("model"))

        let odd = try JSONDecoder().decode(
            HostRunRequest.self,
            from: Data(#"{"device":"mac","requestedMs":5,"model":7,"options":{"thinking":true}}"#.utf8))
        #expect(odd.model == nil)
        #expect(odd.options?.thinking == true)
    }

    @Test func aHostedRunBindsTheCallAndPrivacyForItsRunOnly() async {
        var seen: (Bool, VoiceCallPrivacy?) = (false, nil)
        await BackgroundTaskManager.withHostedRunContext(.init(voiceCall: true, privacy: .off)) {
            seen = (ChatExecutionContext.isVoiceCall, ChatExecutionContext.voiceCallPrivacy)
        }
        #expect(seen.0 == true)
        #expect(seen.1 == .off)
        #expect(ChatExecutionContext.isVoiceCall == false)
        #expect(ChatExecutionContext.voiceCallPrivacy == nil)
    }

    // MARK: - Run detail

    private func call(_ id: String, _ name: String, _ arguments: String = "{}") -> ToolCall {
        ToolCall(id: id, type: "function", function: ToolCallFunction(name: name, arguments: arguments))
    }

    @Test func progressFollowsTheRunThroughItsPhases() throws {
        let user = ChatTurn(role: .user, content: "Find it")
        let reply = ChatTurn(role: .assistant, content: "")
        var progress = try #require(SyncRunProgressContract.snapshot(of: [user, reply], startedMs: 1, nowMs: 2))
        #expect(progress.turn == user.id.uuidString.lowercased())
        #expect(progress.phase == .waiting)

        reply.prefillProgress = PrefillProgressState(stage: .prefill, completedUnitCount: 3, totalUnitCount: 10, detail: nil)
        progress = try #require(SyncRunProgressContract.snapshot(of: [user, reply], startedMs: 1, nowMs: 2))
        #expect(progress.phase == .prefill)
        #expect(progress.prefill == .init(stage: "prefill", done: 3, total: 10))

        reply.prefillProgress = nil
        reply.appendThinking("Let me look")
        progress = try #require(SyncRunProgressContract.snapshot(of: [user, reply], startedMs: 1, nowMs: 2))
        #expect(progress.phase == .thinking)
        #expect(progress.thinkingChars == 11)

        reply.pendingToolName = "web_search"
        reply.pendingToolArgSize = 40
        progress = try #require(SyncRunProgressContract.snapshot(of: [user, reply], startedMs: 1, nowMs: 2))
        #expect(progress.phase == .tool)
        #expect(progress.tools.map(\.state) == [.preparing])
        #expect(progress.tools.first?.argumentBytes == 40)

        reply.pendingToolName = nil
        reply.toolCalls = [call("c1", "web_search", #"{"query":"x"}"#), call("c2", "file_read")]
        reply.toolResults = ["c1": "found"]
        reply.toolCallDurations = ["c1": 1.25]
        progress = try #require(SyncRunProgressContract.snapshot(of: [user, reply], startedMs: 1, nowMs: 2))
        #expect(progress.phase == .tool)
        #expect(progress.tools.map(\.state) == [.done, .running])
        #expect(progress.tools.first?.durationMs == 1250)
        #expect(progress.tools.allSatisfy { !$0.label.isEmpty && !$0.icon.isEmpty })

        reply.toolResults["c2"] = "ok"
        let next = ChatTurn(role: .assistant, content: "Here it is")
        progress = try #require(SyncRunProgressContract.snapshot(of: [user, reply, next], startedMs: 1, nowMs: 2))
        #expect(progress.phase == .answering)
        #expect(progress.tools.count == 2)

        next.imageStep = (4, 20)
        progress = try #require(SyncRunProgressContract.snapshot(of: [user, reply, next], startedMs: 1, nowMs: 2))
        #expect(progress.phase == .image)
        #expect(progress.image == .init(step: 4, total: 20))
    }

    @Test func progressWritesANewShapeAtMostEveryHalfSecondAndCountersEveryTwo() {
        let base = SyncRunProgressContract.Progress(turn: "t", phase: .thinking, thinkingChars: 10, startedMs: 0, updatedMs: 0)
        #expect(SyncRunProgressPublisher.shouldWrite(base, after: nil, writtenMs: 0, nowMs: 0))

        var counted = base
        counted.thinkingChars = 400
        #expect(!SyncRunProgressPublisher.shouldWrite(counted, after: base, writtenMs: 0, nowMs: 1_000))
        #expect(SyncRunProgressPublisher.shouldWrite(counted, after: base, writtenMs: 0, nowMs: 2_000))
        #expect(!SyncRunProgressPublisher.shouldWrite(base, after: base, writtenMs: 0, nowMs: 5_000))

        var answering = base
        answering.phase = .answering
        #expect(!SyncRunProgressPublisher.shouldWrite(answering, after: base, writtenMs: 0, nowMs: 200))
        #expect(SyncRunProgressPublisher.shouldWrite(answering, after: base, writtenMs: 0, nowMs: 500))

        // Through a relay only, both intervals stretch.
        #expect(!SyncRunProgressPublisher.shouldWrite(answering, after: base, writtenMs: 0, nowMs: 500, relayed: true))
        #expect(SyncRunProgressPublisher.shouldWrite(answering, after: base, writtenMs: 0, nowMs: 2_000, relayed: true))
        #expect(!SyncRunProgressPublisher.shouldWrite(counted, after: base, writtenMs: 0, nowMs: 2_000, relayed: true))
        #expect(SyncRunProgressPublisher.shouldWrite(counted, after: base, writtenMs: 0, nowMs: 8_000, relayed: true))
    }

    @Test func progressSlowsDownOnlyWhenEveryConnectedDeviceIsRelayed() {
        func peer(_ id: String, connected: Bool, relayed: Bool) -> PeerConnection {
            PeerConnection(
                device: id, name: id, connected: connected, established: connected, relayed: relayed,
                rttMs: nil, syncing: false, storageRole: false)
        }
        #expect(!SyncRunProgressPublisher.onlyRelayed([]))
        #expect(SyncRunProgressPublisher.onlyRelayed([peer("a", connected: true, relayed: true)]))
        #expect(
            !SyncRunProgressPublisher.onlyRelayed([
                peer("a", connected: true, relayed: true), peer("b", connected: true, relayed: false),
            ]))
        #expect(
            SyncRunProgressPublisher.onlyRelayed([
                peer("a", connected: true, relayed: true), peer("b", connected: false, relayed: false),
            ]))
    }

    @Test func mediumValuesBecomeBlobsBeforeAnyFieldIsDropped() throws {
        let medium = String(repeating: "a", count: 12 * 1024)
        var object: [String: Any] = ["v": 1, "id": "x", "role": "assistant", "thinking": medium]
        for index in 0..<6 { object["field\(index)"] = medium }
        var blobs: [(name: String, bytes: Data)] = []
        var overflow: [String: Any] = [:]
        try SyncConversationMapper.fitTurnObject(&object, blobs: &blobs, overflow: &overflow)
        #expect(overflow.isEmpty)
        #expect(object["truncated"] == nil)
        #expect(object["thinking"] != nil)
        #expect(try SyncConversationMapper.serialize(object).count <= SyncConversationMapper.maxAppDataBytes)
    }

    @Test func aDroppedFieldKeepsItsValueAndItsBlobIsNotWritten() throws {
        let large = String(repeating: "t", count: 20 * 1024)
        var results: [String: Any] = [:]
        // Thousands of tiny results keep the object over the limit on their own.
        for index in 0..<5_000 { results[String(format: "call_%05d", index)] = "okokokok" }
        var object: [String: Any] = ["v": 1, "id": "x", "role": "assistant", "thinking": large, "toolResults": results]
        var blobs: [(name: String, bytes: Data)] = []
        var overflow: [String: Any] = [:]
        try SyncConversationMapper.fitTurnObject(&object, blobs: &blobs, overflow: &overflow)
        #expect((overflow["thinking"] as? String)?.count == large.count)
        #expect(object["thinking"] == nil)
        #expect(object["truncated"] as? Bool == true)
        #expect(!blobs.contains { $0.name == "thinking" })
    }

    @Test func aTurnsGeneratedImageAndToolLabelsGoInItsDetail() async throws {
        try await ChatHistoryTestStorage.run {
            let folder = OsaurusPaths.generatedImages()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = folder.appendingPathComponent("cat.png")
            try Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).write(to: image)
            var turn = ChatTurnData(role: .assistant, content: "![a cat](\(image.absoluteString))")
            turn.toolCalls = [call("c1", "web_search", #"{"query":"cats"}"#)]
            turn.toolResults = ["c1": "results"]
            let encoded = try SyncConversationMapper.encode(turn: turn, toolName: nil)
            let detail = try #require(encoded.detail)
            let object = try #require(SyncConversationMapper.parseObject(detail.bytes))
            let files = try #require(object["files"] as? [[String: Any]])
            #expect(files.count == 1)
            #expect(files.first?["kind"] as? String == "generatedImage")
            #expect(files.first?["mimeType"] as? String == "image/png")
            #expect(files.first?["fileSize"] as? Int == 7)
            #expect(files.first?["blob"] as? Int == 0)
            #expect(files.first?["link"] as? String == image.absoluteString)
            #expect(detail.blobs.count == 1)
            let display = try #require(object["toolCallDisplay"] as? [String: [String: Any]])
            #expect((display["c1"]?["label"] as? String)?.isEmpty == false)
            // The turn's own app data is unchanged by the detail.
            let turnObject = try #require(SyncConversationMapper.parseObject(encoded.appData))
            #expect(turnObject["files"] == nil)
            #expect(turnObject["toolCallDisplay"] == nil)

            let outside = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere.png")
            try Data([1]).write(to: outside)
            let stray = ChatTurnData(role: .assistant, content: "![x](\(outside.absoluteString))")
            #expect(try SyncConversationMapper.encode(turn: stray, toolName: nil).detail == nil)
        }
    }

    @Test func onlyTheDeviceThatWroteAReplyWritesItsDetail() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            defer { SyncService.shared.close() }
            var reply = ChatTurnData(role: .assistant, content: "Done")
            reply.toolCalls = [call("c1", "file_read")]
            var session = ChatSessionData(
                title: "Detail", turns: [ChatTurnData(role: .user, content: "hi"), reply])
            try SyncConversationStore.shared.saveSession(session)
            let scope = try #require(SyncConversationStore.shared.scope(forSession: session.id))
            func stored() throws -> SyncMessage {
                try #require(try core.messages(scope: scope, before: nil, limit: 10).messages.last)
            }
            let first = try #require(try stored().appData(SyncConversationMapper.turnDetailNamespace))
            let running = try #require(SyncConversationMapper.parseObject(first.bytes))
            #expect(((running["toolCallDisplay"] as? [String: Any])?["c1"]) != nil)

            session.turns[1].toolResults = ["c1": "contents"]
            try SyncConversationStore.shared.saveSession(session)
            let second = try #require(try stored().appData(SyncConversationMapper.turnDetailNamespace))
            #expect(second.bytes != first.bytes)
        }
    }

    // MARK: - Management

    @Test func anOpThisMacDoesNotKnowIsAnsweredNotDropped() async throws {
        let json = #"{"requests":[{"id":"r1","op":"teleport","requestedMs":1}]}"#
        let decoded = try JSONDecoder().decode(SyncDeviceFeedContract.ManageRequests.self, from: Data(json.utf8))
        let request = try #require(decoded.requests.first)
        #expect(request.op == .unsupported)
        let result = await SyncManageFeed.perform(request)
        #expect(!result.ok)
        #expect(result.error == "unsupported_op")
    }

    @Test func newOpsWithoutTheirFieldsAreBadRequests() async {
        let agent = Agent.defaultId.uuidString.lowercased()
        let requests: [SyncDeviceFeedContract.ManageRequest] = [
            .init(id: "f", op: .setFavorite, key: "  ", favorite: true, requestedMs: 1),
            .init(id: "o", op: .getModelOptions, requestedMs: 1),
            .init(id: "s", op: .setModelOption, model: "m", requestedMs: 1),
            .init(id: "t", op: .setTool, agentId: agent, requestedMs: 1),
            .init(id: "c", op: .contextUsage, requestedMs: 1),
        ]
        for request in requests {
            let result = await SyncManageFeed.perform(request)
            #expect(result.error == "bad_request", "\(request.id): \(result.error ?? "ok")")
        }
    }

    @Test func anAnswerLargerThanTheResultCapIsRefused() {
        let small = SyncManageFeed.answered(["favorites": ["local:a"]])
        #expect(small.ok)
        #expect(small.data == .object(["favorites": .array([.string("local:a")])]))
        let large = SyncManageFeed.answered(["text": String(repeating: "x", count: SyncDeviceFeedContract.resultDataLimit)])
        #expect(!large.ok)
        #expect(large.error == "too_large")
        #expect(large.data == nil)
    }

    @Test func aLongModelListTravelsAsABlobAndItsDigestIgnoresTheClock() throws {
        let short = try #require(
            SyncManageDetail.modelsPayload(models: HTTPHandler.pickerModels(picker, allItems: picker), favorites: ["local:x"]))
        let inline = try #require(SyncConversationMapper.parseObject(short.object))
        #expect((inline["models"] as? [Any])?.count == 2)
        #expect(inline["favorites"] as? [String] == ["local:x"])
        #expect(short.blobs.isEmpty)

        let many = (0 ..< 400).map {
            ModelPickerItem(id: "provider/model-with-a-long-name-\($0)", displayName: "Model \($0)", source: .local)
        }
        let long = try #require(
            SyncManageDetail.modelsPayload(models: HTTPHandler.pickerModels(many, allItems: many), favorites: []))
        let object = try #require(SyncConversationMapper.parseObject(long.object))
        let reference = try #require(object["models"] as? [String: Any])
        #expect(reference["$blob"] as? Int == 0)
        #expect(long.blobs.count == 1)
        let rows = try #require(try JSONSerialization.jsonObject(with: long.blobs[0].bytes) as? [Any])
        #expect(rows.count == 400)

        let again = try #require(
            SyncManageDetail.modelsPayload(models: HTTPHandler.pickerModels(many, allItems: many), favorites: []))
        #expect(again.digest == long.digest)
        let other = try #require(
            SyncManageDetail.modelsPayload(models: HTTPHandler.pickerModels(many, allItems: many), favorites: ["local:x"]))
        #expect(other.digest != long.digest)
    }

    @Test func anAgentsDetailCarriesItsPromptAndTools() throws {
        var agent = Agent(name: "Writer")
        agent.systemPrompt = "Be brief."
        let payload = try #require(SyncManageDetail.agentPayload(agent, tools: []))
        let object = try #require(SyncConversationMapper.parseObject(payload.object))
        #expect(object["agentId"] as? String == agent.id.uuidString.lowercased())
        #expect(object["systemPrompt"] as? String == "Be brief.")
        #expect((object["tools"] as? [Any])?.isEmpty == true)
        #expect(object["avatarImage"] == nil)

        agent.systemPrompt = String(repeating: "p", count: SyncManageDetail.inlineLimit + 1)
        let long = try #require(SyncManageDetail.agentPayload(agent, tools: []))
        let reference = try #require(SyncConversationMapper.parseObject(long.object)?["systemPrompt"] as? [String: Any])
        #expect(reference["$blob"] as? Int == 0)
        #expect(try JSONSerialization.jsonObject(with: long.blobs[0].bytes, options: .fragmentsAllowed) as? String
            == agent.systemPrompt)
    }

    @Test func detailMessagesAreSentRewrittenAndRemovedWithTheirAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            defer { SyncService.shared.close() }
            let models = try #require(SyncManageDetail.modelsPayload(models: [], favorites: []))
            var writer = Agent(name: "Writer")
            let reader = Agent(name: "Reader")
            func payloads() throws -> [SyncManageDetail.Payload] {
                [models, try #require(SyncManageDetail.agentPayload(writer, tools: [])),
                 try #require(SyncManageDetail.agentPayload(reader, tools: []))]
            }

            // Nothing before the manage state made the conversation.
            try SyncManageDetail.write(try payloads(), core: core)
            #expect(try SyncDeviceFeedContract.conversation(
                kind: SyncDeviceFeedContract.manageKind, device: core.deviceKey(), core: core) == nil)

            let state = SyncManageFeed.state(device: core.deviceKey(), agents: [], models: [])
            try SyncManageFeed.publish(state, core: core, createIfMissing: true)
            let scope = try #require(try SyncDeviceFeedContract.conversation(
                kind: SyncDeviceFeedContract.manageKind, device: core.deviceKey(), core: core)).scope
            func detail() throws -> [String: SyncMessage] {
                var byKey: [String: SyncMessage] = [:]
                for message in try core.messages(scope: scope, before: nil, limit: 50).messages {
                    if let (key, _) = SyncManageDetail.detailKey(of: message) { byKey[key] = message }
                }
                return byKey
            }

            try SyncManageDetail.write(try payloads(), core: core)
            let first = try detail()
            let writerKey = writer.id.uuidString.lowercased()
            let readerKey = reader.id.uuidString.lowercased()
            #expect(Set(first.keys) == [SyncManageDetail.modelsKey, writerKey, readerKey])
            #expect(first[SyncManageDetail.modelsKey]?.content == SyncDeviceFeedContract.modelsMessageContent)
            #expect(first[writerKey]?.content == SyncDeviceFeedContract.agentDetailMessageContent)

            try SyncManageDetail.write(try payloads(), core: core)
            #expect(try detail().mapValues(\.id) == first.mapValues(\.id))

            writer.systemPrompt = "Changed"
            let changed = try #require(SyncManageDetail.agentPayload(writer, tools: []))
            try SyncManageDetail.write([models, changed], core: core)
            let after = try detail()
            #expect(Set(after.keys) == [SyncManageDetail.modelsKey, writerKey])
            #expect(after[writerKey]?.id == first[writerKey]?.id)
            let stored = try #require(after[writerKey]?.appData(SyncDeviceFeedContract.agentDetailNamespace))
            #expect(SyncConversationMapper.parseObject(stored.bytes)?["systemPrompt"] as? String == "Changed")
        }
    }

    // MARK: - Attention detail

    private func waitForPending(_ kind: AttentionKind) async throws -> AttentionItem {
        for _ in 0 ..< 400 {
            if let item = AttentionCenter.shared.pending.last(where: { $0.kind == kind }) { return item }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }

    private func answer(_ id: UUID, _ action: String, redact: [String]? = nil) {
        var applied: Set<String> = []
        SyncAttentionFeed.apply(
            [.init(id: id.uuidString, answer: .init(action: action, redact: redact, answeredMs: SyncHostedRunContract.nowMs()),
                   deviceLabel: "Tae's iPhone")],
            applied: &applied, center: .shared)
    }

    private func wireDetail(_ item: AttentionItem) -> [String: Any]? {
        PairedDeviceChannel.wire(item)["detail"] as? [String: Any]
    }

    @Test func aConfigPlanCarriesItsActionsAndALongOneSaysTruncated() throws {
        let small = ConfigPlan(actions: [.init(section: "agents", target: "Writer", kind: .update, changes: ["model"])])
        let detail = try #require(ConfigApprovalQueue.detail(plan: small, prune: true))
        let object = try #require(SyncConversationMapper.parseObject(detail))
        #expect(object["prune"] as? Bool == true)
        #expect((object["actions"] as? [[String: Any]])?.first?["target"] as? String == "Writer")
        #expect(object["truncated"] == nil)

        let long = ConfigPlan(actions: (0 ..< 400).map {
            .init(section: "agents", target: "Agent \($0)", kind: .create, changes: ["name", "model", "prompt"])
        })
        let cut = try #require(ConfigApprovalQueue.detail(plan: long, prune: false))
        #expect(cut.count <= AttentionDetail.limit)
        let trimmed = try #require(SyncConversationMapper.parseObject(cut))
        #expect(trimmed["truncated"] as? Bool == true)
        #expect(trimmed["total"] as? Int == 400)
        #expect((1 ..< 400).contains((trimmed["actions"] as? [Any])?.count ?? 0))
    }

    @Test func computerUseOffersApproveRestWhenTheStepHasAnApp() async throws {
        let queue = ComputerUsePromptQueue.shared
        let toolCallId = "cu-\(UUID())"
        defer { queue.cancelAll(forToolCallId: toolCallId) }
        let typed = String(repeating: "a", count: ComputerUsePromptQueue.typedTextDetailLimit + 10)
        let preview = ActionPreview(
            appName: "Notes", actionLabel: "Type", targetLabel: "Body", effect: .edit, note: nil, typedText: typed)
        let first = Task { @MainActor in await queue.requestConfirmation(preview, toolCallId: toolCallId) }
        let item = try await waitForPending(.computerUse)
        #expect(item.actions.contains(.approveRest))
        let detail = try #require(wireDetail(item))
        #expect(detail["app"] as? String == "Notes")
        #expect(detail["effect"] as? String == "edit")
        #expect((detail["typedText"] as? String)?.count == ComputerUsePromptQueue.typedTextDetailLimit)
        #expect(detail["truncated"] as? Bool == true)

        answer(item.id, "approve_rest")
        #expect(await first.value)
        #expect(AttentionCenter.shared.recent.first { $0.id == item.id }?.resolution?.outcome == .allowedForConversation)
        // The rest of the run's steps in Notes at that effect go ahead.
        let next = ActionPreview(appName: "Notes", actionLabel: "Type", targetLabel: "Title", effect: .navigate, note: nil)
        #expect(await queue.requestConfirmation(next, toolCallId: toolCallId))
    }

    @Test func approveRestIsIgnoredWhereTheItemDoesNotOfferIt() async throws {
        let queue = ComputerUsePromptQueue.shared
        let toolCallId = "cu-\(UUID())"
        defer { queue.cancelAll(forToolCallId: toolCallId) }
        let preview = ActionPreview(appName: nil, actionLabel: "Press Return", targetLabel: nil, effect: .edit, note: nil)
        let run = Task { @MainActor in await queue.requestConfirmation(preview, toolCallId: toolCallId) }
        let item = try await waitForPending(.computerUse)
        #expect(!item.actions.contains(.approveRest))
        answer(item.id, "approve_rest")
        #expect(AttentionCenter.shared.item(id: item.id)?.isPending == true)
        answer(item.id, "deny")
        #expect(await run.value == false)
    }

    private func detection(_ name: String) async -> DetectedEntity {
        let placeholder = await RedactionMap(conversationID: UUID()).intern(name, as: .person)
        return DetectedEntity(
            category: .person, original: name, range: name.startIndex ..< name.endIndex, placeholder: placeholder,
            approved: true)
    }

    private func hostedReview(_ detections: [DetectedEntity]) -> Task<PrivacyReviewOutcome, Never> {
        Task { @MainActor in
            await ChatExecutionContext.$syncReviewerScope.withValue("scope") {
                await PrivacyReviewService.shared.review(
                    detections: detections, sessionId: UUID().uuidString,
                    allowInteractive: !ChatExecutionContext.reviewsElsewhere,
                    allowRemote: ChatExecutionContext.reviewsElsewhere)
            }
        }
    }

    @Test func aHostedRunsPrivacyReviewIsAnsweredFromTheFeedWithWhatToRedact() async throws {
        let sandbox = await acquirePrivacyStoreSandbox("SyncMobileV2Tests")
        defer { sandbox.release() }
        PrivacyFilterStore.save(PrivacyFilterConfiguration())
        let alice = await detection("Alice")
        let bob = await detection("Bob")
        let review = hostedReview([alice, bob])
        let item = try await waitForPending(.privacyReview)
        let rows = try #require(wireDetail(item)?["items"] as? [[String: Any]])
        #expect(rows.map { $0["original"] as? String } == ["Alice", "Bob"])
        #expect(rows.first?["category"] as? String == "person")
        #expect(rows.first?["placeholder"] as? String == alice.placeholder.token)

        answer(item.id, "approve", redact: [bob.id.uuidString])
        guard case .approved(let entities) = await review.value else {
            Issue.record("expected approved")
            return
        }
        #expect(entities.first { $0.id == alice.id }?.approved == false)
        #expect(entities.first { $0.id == bob.id }?.approved == true)
    }

    @Test func aDeniedPrivacyReviewStopsTheSendAndApproveAloneRedactsAll() async throws {
        let sandbox = await acquirePrivacyStoreSandbox("SyncMobileV2Tests")
        defer { sandbox.release() }
        PrivacyFilterStore.save(PrivacyFilterConfiguration())
        let alice = await detection("Alice")

        let denied = hostedReview([alice])
        answer(try await waitForPending(.privacyReview).id, "deny")
        guard case .canceled = await denied.value else {
            Issue.record("expected canceled")
            return
        }

        let approved = hostedReview([alice])
        answer(try await waitForPending(.privacyReview).id, "approve")
        guard case .approved(let entities) = await approved.value else {
            Issue.record("expected approved")
            return
        }
        let redactedAll = entities.allSatisfy(\.approved)
        #expect(redactedAll)
    }

    @Test func detailPastTheFeedBudgetSaysTruncated() {
        let big = Data(try! JSONSerialization.data(withJSONObject: ["text": String(repeating: "x", count: 7_000)]))
        let items = (0 ..< 6).map { _ -> AttentionItem in
            var item = AttentionItem(kind: .configApproval, title: "Apply?")
            item.detail = big
            return item
        }
        let payload = SyncAttentionFeed.payload(items: items, recent: [])
        let rows = payload["items"] as? [[String: Any]] ?? []
        let full = rows.filter { ($0["detail"] as? [String: Any])?["text"] != nil }.count
        #expect(full == SyncAttentionFeed.detailBudget / big.count)
        #expect((rows.last?["detail"] as? [String: Any])?["truncated"] as? Bool == true)
    }

    // MARK: - Images

    @Test func anImageRunsSettingsOverlayTheModelDefaultsTheyName() {
        let base = ImageComposerSettings(steps: 4, guidance: 0, width: 1024, height: 1024)
        let chosen = HostRunRequest.ImageSettings(
            width: 768, steps: 8, seed: 42, negativePrompt: "blur", aspectRatio: "16:9", count: 2)
        let settings = chosen.applied(to: base)
        #expect(settings.width == 768)
        #expect(settings.height == 1024)
        #expect(settings.steps == 8)
        #expect(settings.guidance == 0)
        #expect(settings.seed == "42")
        #expect(settings.negativePrompt == "blur")
        #expect(settings.aspectRatio == "16:9")
        #expect(settings.imageCount == 2)
        #expect(settings.stepsWereExplicitlySet == true)
        #expect(settings.guidanceWasExplicitlySet == true)
        #expect(HostRunRequest.ImageSettings().applied(to: base) == base)
    }

    @Test func anImageRunsChoicesReachTheDispatch() throws {
        let image = ModelPickerItem(id: "flux-schnell", displayName: "FLUX", source: .local)
        let marker = HostRunRequest(
            device: "mac", requestedMs: 1, model: "flux-schnell", image: .init(width: 512, steps: 4, count: 1))
        let choices = try SyncHostRunner.choices(
            for: marker, requester: "p1", me: "mac", devices: [device("p1", "Phone")], pickerItems: picker + [image]
        ).get()
        #expect(choices.run?.model == "flux-schnell")
        #expect(choices.run?.image == .init(width: 512, steps: 4, count: 1))
    }

    // MARK: - Workspace agents

    private let teammateAddress = "0x" + String(repeating: "ab", count: 20)
    private let ownAddress = "0x" + String(repeating: "cd", count: 20)

    private func roster() -> WorkspaceRosterStore.WorkspaceRoster {
        func agent(_ address: String, _ name: String?, owner: String?) -> OsaurusRouterWorkspaceAgent {
            OsaurusRouterWorkspaceAgent(
                agentAddress: address, displayName: name, description: nil,
                owner: OsaurusRouterWorkspacePerson(accountId: nil, walletAddress: nil, displayName: owner),
                relayURL: nil, online: true, lastSeen: nil, sharedAt: nil)
        }
        return WorkspaceRosterStore.WorkspaceRoster(
            workspace: OsaurusRouterWorkspaceSummary(id: "ws1", name: "Studio", role: "member", active: true),
            agents: [agent(teammateAddress.uppercased(), "Researcher", owner: "Sam"), agent(ownAddress, "Mine", owner: "Me")])
    }

    @Test func theManageStateListsTeammatesSharedAgentsButNotTheUsersOwn() {
        let listed = SyncManageFeed.workspaceAgents(rosters: [roster()], localAddresses: [ownAddress])
        #expect(listed == [
            .init(workspaceId: "ws1", workspaceName: "Studio", address: teammateAddress, name: "Researcher", ownerName: "Sam")
        ])
        let state = SyncManageFeed.state(device: "mac", agents: [], models: [], workspaceAgents: listed)
        #expect(state.workspaceAgents?.first?.address == teammateAddress)
    }

    @Test func aChatWithASharedAgentRunsTowardItWhileItIsStillShared() throws {
        var session = ChatSessionData(title: "Team")
        #expect(try SyncHostRunner.workspaceTarget(for: session, listed: []).get() == nil)

        session.workspace = WorkspaceSessionContext(workspaceId: "ws1", agentAddress: teammateAddress)
        let ref = WorkspaceAgentRef(workspaceId: "ws1", agentAddress: teammateAddress)
        #expect(try SyncHostRunner.workspaceTarget(for: session, listed: [ref.key]).get() == ref)
        guard case .failure = SyncHostRunner.workspaceTarget(for: session, listed: []) else {
            Issue.record("an unshared agent should be declined")
            return
        }

        // A chat this Mac served for a teammate isn't one to run toward.
        session.workspace?.callerWallet = "0x" + String(repeating: "ef", count: 20)
        #expect(try SyncHostRunner.workspaceTarget(for: session, listed: [ref.key]).get() == nil)
    }

    @Test func aWorkspaceChatContinuesOnlyTowardTheSameAgent() {
        let ref = WorkspaceAgentRef(workspaceId: "ws1", agentAddress: teammateAddress)
        var shared = ChatSessionData(title: "Team")
        shared.workspace = WorkspaceSessionContext(workspaceId: "ws1", agentAddress: teammateAddress.uppercased())
        #expect(BackgroundTaskManager.continues(shared, agentId: nil, workspace: ref))
        #expect(!BackgroundTaskManager.continues(
            shared, agentId: nil, workspace: WorkspaceAgentRef(workspaceId: "ws2", agentAddress: teammateAddress)))
        #expect(!BackgroundTaskManager.continues(shared, agentId: shared.agentId, workspace: nil))

        let local = ChatSessionData(title: "Mine", agentId: Agent.defaultId)
        #expect(BackgroundTaskManager.continues(local, agentId: Agent.defaultId, workspace: nil))
        #expect(!BackgroundTaskManager.continues(local, agentId: nil, workspace: ref))
    }

    // MARK: - Reachability

    @Test func theMacAsksOnceAboutAnywhereWhenAnIPhoneJoinsOnSameNetwork() {
        let same = SyncConfiguration(networkMode: .localNetworkOnly)
        #expect(SyncReachabilityPrompt.shouldAsk(hasPhone: true, configuration: same, asked: false))
        #expect(!SyncReachabilityPrompt.shouldAsk(hasPhone: true, configuration: same, asked: true))
        #expect(!SyncReachabilityPrompt.shouldAsk(hasPhone: false, configuration: same, asked: false))
        #expect(!SyncReachabilityPrompt.shouldAsk(
            hasPhone: true, configuration: SyncConfiguration(networkMode: .anywhere), asked: false))
        #expect(!SyncReachabilityPrompt.shouldAsk(
            hasPhone: true, configuration: SyncConfiguration(networkEnabled: false), asked: false))
    }

    @Test func theAnywhereQuestionOpensInTheWindowTheUserIsIn() {
        let chat = UUID()
        #expect(SyncReachabilityPrompt.scope(focusedChat: chat, chatVisible: { _ in true }, managementVisible: true)
            == .chat(chat))
        #expect(SyncReachabilityPrompt.scope(focusedChat: chat, chatVisible: { _ in false }, managementVisible: true)
            == .management)
        #expect(SyncReachabilityPrompt.scope(focusedChat: nil, chatVisible: { _ in true }, managementVisible: false)
            == .toastOverlay)
    }

    @Test func anOlderDirectoryWithoutTheNewFieldsStillDecodes() throws {
        let json = #"{"v":1,"device":"d","updatedMs":1,"agents":[{"id":"x","name":"A"}]}"#
        let directory = try JSONDecoder().decode(SyncHostedRunContract.Directory.self, from: Data(json.utf8))
        #expect(directory.features == nil)
        #expect(directory.presence == nil)
        #expect(directory.agents.first?.name == "A")
    }
}
