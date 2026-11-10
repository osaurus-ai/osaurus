//
//  SyncMobileProtocolTests.swift
//  OsaurusCoreTests
//
//  What an iPhone does with a Mac through Sync (docs/SYNC_MOBILE_CONTRACT.md):
//  secrets a hosted run asks for come back sealed and open only on the
//  host, attention answers resolve the item once and only with an answer it
//  offers, management requests go through the Mac's own editor, and the
//  Default agent is offered to iPhones but not to other Macs.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite("Mobile Sync protocol", .serialized)
@MainActor
struct SyncMobileProtocolTests {
    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Secrets

    @Test func aSealedSecretOpensOnlyForItsPromptAndScope() async throws {
        let queue = SyncSecretPromptQueue.shared
        let scope = "scope-\(UUID().uuidString)"
        let waiting = Task { @MainActor in
            await queue.request(scope: scope, key: "OPENAI_API_KEY", description: "For the script", instructions: "")
        }
        try await waitUntil("a pending prompt") { !queue.pending(scope: scope).isEmpty }
        let request = try #require(queue.pending(scope: scope).first)
        let promptId = request.id.uuidString.lowercased()

        // Sealed for a different prompt: refused, and the prompt stays.
        let misbound = try PairingKeyEnvelope.seal(
            secret: "sk-wrong",
            recipientPublicKeyBase64url: request.sealKey,
            info: SyncHostedRunContract.promptSealInfo(UUID().uuidString)
        )
        #expect(!queue.resolve(id: request.id, scope: scope, answer: .init(sealed: misbound), deviceLabel: "Your iPhone"))
        // The right seal from the wrong conversation: refused.
        let sealed = try PairingKeyEnvelope.seal(
            secret: "sk-live-123",
            recipientPublicKeyBase64url: request.sealKey,
            info: SyncHostedRunContract.promptSealInfo(promptId)
        )
        #expect(!queue.resolve(id: request.id, scope: "elsewhere", answer: .init(sealed: sealed), deviceLabel: "Your iPhone"))
        #expect(queue.resolve(id: request.id, scope: scope, answer: .init(sealed: sealed), deviceLabel: "Your iPhone"))
        #expect(await waiting.value == "sk-live-123")
        #expect(queue.pending(scope: scope).isEmpty)
        // The Mac's Inbox and the other devices' feeds stop showing it, and
        // it records who sent it.
        let item = try #require(AttentionCenter.shared.item(id: request.id))
        #expect(item.state == .resolved(
            AttentionResolution(outcome: .replied, surface: .phone, decidedBy: .ownerDevice("Your iPhone"))))
    }

    @Test func aDeclinedOrEndedPromptReturnsNothing() async throws {
        let queue = SyncSecretPromptQueue.shared
        let scope = "scope-\(UUID().uuidString)"
        let declined = Task { @MainActor in
            await queue.request(scope: scope, key: "TOKEN", description: "", instructions: "")
        }
        try await waitUntil("a pending prompt") { !queue.pending(scope: scope).isEmpty }
        let first = try #require(queue.pending(scope: scope).first)
        #expect(queue.resolve(id: first.id, scope: scope, answer: .init(cancel: true), deviceLabel: "Your iPhone"))
        #expect(await declined.value == nil)

        let ended = Task { @MainActor in
            await queue.request(scope: scope, key: "TOKEN", description: "", instructions: "")
        }
        try await waitUntil("a second pending prompt") { !queue.pending(scope: scope).isEmpty }
        queue.cancelAll(scope: scope)
        #expect(await ended.value == nil)
    }

    @Test func theAnswerIsWrittenSealedNeverPlain() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            defer { SyncService.shared.close() }
            let recipient = PairingKeyEnvelope.generateRecipientKey()
            let prompt = SyncHostedRunContract.PendingPrompt(
                id: UUID().uuidString.lowercased(),
                turnId: UUID().uuidString.lowercased(),
                kind: .secret,
                key: "GITHUB_TOKEN",
                description: "",
                instructions: "",
                sealKey: recipient.publicKeyBase64url,
                requestedMs: SyncHostedRunContract.nowMs()
            )
            let scope = try core.createConversation(title: "Hosted", replication: .synced)
            try core.setConversationAppData(
                scope: scope,
                namespace: SyncHostedRunContract.promptNamespace,
                bytes: try SyncHostedRunContract.encode(SyncHostedRunContract.Prompts(pending: [prompt]))
            )
            let sealed = try PairingKeyEnvelope.seal(
                secret: "ghp_secretvalue",
                recipientPublicKeyBase64url: prompt.sealKey,
                info: SyncHostedRunContract.promptSealInfo(prompt.id)
            )
            let conversation = try #require(try core.conversation(scope: scope))
            try SyncHostedRunMonitor.writePromptAnswer(
                .init(sealed: sealed),
                id: prompt.id,
                core: core,
                scope: scope,
                conversation: conversation
            )
            let stored = try #require(try core.conversation(scope: scope))
            let bytes = try #require(stored.appData(SyncHostedRunContract.promptAnswerNamespace))
            #expect(!String(decoding: bytes, as: UTF8.self).contains("ghp_secretvalue"))
            let answers = try #require(
                SyncHostedRunContract.read(
                    SyncHostedRunContract.PromptAnswers.self,
                    SyncHostedRunContract.promptAnswerNamespace,
                    from: stored
                )
            )
            let opened = try PairingKeyEnvelope.open(
                try #require(answers.answers[prompt.id]?.sealed),
                privateKey: recipient.privateKey,
                info: SyncHostedRunContract.promptSealInfo(prompt.id)
            )
            #expect(opened == "ghp_secretvalue")
            #expect(SyncHostedRunMonitor.unansweredPrompts(in: stored).isEmpty)
        }
    }

    @Test func promptAnswersSkipShapesTheyDontKnow() throws {
        let json = #"{"v":1,"answers":{"a":{"cancel":true},"b":{"sealed":{"enc":"x","ct":"y"}},"c":{"sealed":7}}}"#
        let answers = try JSONDecoder().decode(SyncHostedRunContract.PromptAnswers.self, from: Data(json.utf8))
        #expect(answers.answers["a"]?.cancel == true)
        #expect(answers.answers["b"]?.sealed == PairingKeyEnvelope.Sealed(enc: "x", ct: "y"))
        #expect(answers.answers["c"] == nil)
    }

    // MARK: - Attention

    @Test func anAttentionAnswerResolvesOnceWithWhatTheItemOffers() {
        let center = AttentionCenter(channels: [])
        var settled: [AttentionResolution] = []
        let approval = center.raise(AttentionItem(kind: .toolApproval, title: "Allow web_fetch?")) { settled.append($0) }
        let question = center.raise(AttentionItem(kind: .clarification, title: "Which repo?"))
        let now = SyncHostedRunContract.nowMs()
        var applied: Set<String> = []

        // Not offered, a reply with no text, and a stale answer: all ignored.
        SyncAttentionFeed.apply(
            [
                approval.uuidString: .init(action: "allow_for_conversation", text: nil, answeredMs: now),
                question.uuidString: .init(action: "reply", text: "  ", answeredMs: now),
            ],
            applied: &applied,
            deviceLabel: "Your iPhone",
            center: center,
            nowMs: now
        )
        SyncAttentionFeed.apply(
            [approval.uuidString: .init(action: "approve", text: nil, answeredMs: now - SyncDeviceFeedContract.requestTTLMs - 1)],
            applied: &applied,
            deviceLabel: "Your iPhone",
            center: center,
            nowMs: now
        )
        #expect(center.item(id: approval)?.isPending == true)
        #expect(center.item(id: question)?.isPending == true)

        SyncAttentionFeed.apply(
            [
                approval.uuidString: .init(action: "approve", text: nil, answeredMs: now),
                question.uuidString: .init(action: "reply", text: "osaurus", answeredMs: now),
            ],
            applied: &applied,
            deviceLabel: "Your iPhone",
            center: center,
            nowMs: now
        )
        #expect(settled.map(\.outcome) == [.approved])
        #expect(settled.first?.surface == .phone)
        #expect(center.item(id: question)?.resolution?.replyText == "osaurus")

        // Re-reading the same answers applies nothing again.
        SyncAttentionFeed.apply(
            [approval.uuidString: .init(action: "approve", text: nil, answeredMs: now)],
            applied: &applied,
            deviceLabel: "Your iPhone",
            center: center,
            nowMs: now
        )
        #expect(settled.count == 1)
    }

    @Test func aPendingToolApprovalShowsWhatItWouldRun() throws {
        var item = AttentionItem(kind: .toolApproval, title: "Allow shell?")
        item.argumentsPreview = #"{"cmd":"rm -rf /tmp/x"}"#
        let body = SyncAttentionFeed.payload(items: [item], recent: [])
        let listed = try #require((body["items"] as? [[String: Any]])?.first)
        #expect(listed["title"] as? String == "Allow shell?")
        #expect(listed["arguments_preview"] as? String == #"{"cmd":"rm -rf /tmp/x"}"#)

        item.argumentsPreview = String(repeating: "a", count: 600)
        let long = PairedDeviceChannel.wire(item)
        #expect((long["arguments_preview"] as? String)?.count == PairedDeviceChannel.argumentsPreviewLimit)
    }

    @Test func settledItemsDropTheirArguments() {
        var item = AttentionItem(kind: .toolApproval, title: "Allow shell?")
        item.argumentsPreview = #"{"cmd":"ls"}"#
        item.state = .retracted
        #expect(PairedDeviceChannel.wire(item)["arguments_preview"] == nil)
    }

    // MARK: - Managing agents

    @Test func theDefaultAgentIsListedWithItsModelOnly() {
        let mine = Agent(name: "Researcher")
        let state = SyncManageFeed.state(device: "mac", agents: [.default, mine], models: [])
        let fallback = state.agents.first { $0.id == Agent.defaultId.uuidString.lowercased() }
        #expect(fallback?.isDefault == true)
        #expect(fallback?.settings == nil)
        let listed = state.agents.first { $0.id == mine.id.uuidString.lowercased() }
        #expect(listed?.isDefault == nil)
        #expect(listed?.settings != nil)
    }

    @Test func managementRequestsGoThroughTheMacsEditor() async throws {
        let created = await SyncManageFeed.perform(
            .init(id: "c1", op: .createAgent, name: "  Phone Made  ", requestedMs: SyncHostedRunContract.nowMs())
        )
        #expect(created.ok)
        let agentId = try #require(created.agentId.flatMap(UUID.init(uuidString:)))
        defer { Task { @MainActor in _ = await AgentManager.shared.delete(id: agentId) } }
        #expect(AgentManager.shared.agent(for: agentId)?.name == "Phone Made")

        let renamed = await SyncManageFeed.perform(
            .init(id: "u1", op: .updateAgent, agentId: agentId.uuidString, name: "Scout", requestedMs: 0)
        )
        #expect(renamed.ok)
        #expect(AgentManager.shared.agent(for: agentId)?.name == "Scout")

        let badPreset = await SyncManageFeed.perform(
            .init(id: "p1", op: .setToolPreset, agentId: agentId.uuidString, preset: "most", requestedMs: 0)
        )
        #expect(badPreset.error == "bad_request")

        let deleteDefault = await SyncManageFeed.perform(
            .init(id: "d0", op: .deleteAgent, agentId: Agent.defaultId.uuidString, requestedMs: 0)
        )
        #expect(deleteDefault.error == "agent_not_editable")

        let deleted = await SyncManageFeed.perform(
            .init(id: "d1", op: .deleteAgent, agentId: agentId.uuidString, requestedMs: 0)
        )
        #expect(deleted.ok)
        #expect(AgentManager.shared.agent(for: agentId) == nil)
    }

    @Test func oversizedManagementRequestsAreRefusedBeforeTheyRun() async {
        let long = await SyncManageFeed.perform(
            .init(
                id: "big", op: .createAgent, name: "Big",
                systemPrompt: String(repeating: "x", count: SyncManageFeed.systemPromptLimit + 1), requestedMs: 0)
        )
        #expect(long.error == "bad_request")
        #expect(AgentManager.shared.agents.allSatisfy { $0.name != "Big" })
        #expect(
            SyncManageFeed.oversized(.init(id: "n", op: .updateAgent, name: String(repeating: "n", count: 201), requestedMs: 0))
                != nil)
        #expect(SyncManageFeed.oversized(.init(id: "ok", op: .updateAgent, name: "Scout", requestedMs: 0)) == nil)
    }

    @Test func answersNameTheOnlyIPhoneOrSayYourIPhone() {
        func device(_ id: String, _ name: String, _ platform: String, revoked: Bool = false, isSelf: Bool = false) -> Device {
            Device(id: id, user: "u", name: name, platform: platform, lastSeenMs: nil, revoked: revoked, isSelf: isSelf)
        }
        let mac = device("m", "Studio", "macos", isSelf: true)
        let phone = device("p1", "Tae's iPhone", "ios")
        let oldPhone = device("p0", "Old iPhone", "ios", revoked: true)
        #expect(SyncAttentionFeed.answerLabel(devices: [mac, phone, oldPhone]) == "Tae's iPhone")
        #expect(SyncAttentionFeed.answerLabel(devices: [mac, phone, device("p2", "Work iPhone", "ios")]) == "Your iPhone")
        #expect(SyncAttentionFeed.answerLabel(devices: [mac]) == "Your iPhone")
    }

    private func manageRequests(_ count: Int, at nowMs: Int64) -> [SyncDeviceFeedContract.ManageRequest] {
        (0 ..< count).map { .init(id: "r\($0)", op: .createAgent, name: "Agent \($0)", requestedMs: nowMs) }
    }

    @Test func eachManagementRequestRunsOnceHoweverManyAreListed() async {
        let nowMs = SyncHostedRunContract.nowMs()
        let requests = manageRequests(60, at: nowMs)
        var ledger = SyncManageFeed.Ledger()
        var runs: [String: Int] = [:]
        func perform(_ request: SyncDeviceFeedContract.ManageRequest) async -> SyncDeviceFeedContract.ManageResult {
            runs[request.id, default: 0] += 1
            return .init(ok: true, doneMs: nowMs)
        }
        let first = await SyncManageFeed.apply(
            requests: requests, synced: [:], ledger: &ledger, nowMs: nowMs, save: { _ in }, perform: perform)
        #expect(first.applied == 60)
        #expect(first.results.count == 60)

        // The iPhone kept every request, and the synced results came back
        // empty: nothing runs again, and every result is written back.
        let again = await SyncManageFeed.apply(
            requests: requests, synced: [:], ledger: &ledger, nowMs: nowMs + 1, save: { _ in }, perform: perform)
        #expect(again.applied == 0)
        #expect(again.results == first.results)
        #expect(runs.count == 60)
        #expect(runs.values.allSatisfy { $0 == 1 })

        // Results follow the list: a request the iPhone removed drops out.
        let fewer = await SyncManageFeed.apply(
            requests: Array(requests.prefix(10)), synced: first.results, ledger: &ledger, nowMs: nowMs + 2,
            save: { _ in }, perform: perform)
        #expect(Set(fewer.results.keys) == Set(requests.prefix(10).map(\.id)))
    }

    @Test func aRequestInterruptedMidRunIsNotRunAgainAfterRelaunch() async throws {
        let nowMs = SyncHostedRunContract.nowMs()
        let requests = manageRequests(2, at: nowMs)
        var saved: [SyncManageFeed.Ledger] = []
        var ledger = SyncManageFeed.Ledger()
        _ = await SyncManageFeed.apply(
            requests: requests, synced: [:], ledger: &ledger, nowMs: nowMs,
            save: { saved.append($0) }, perform: { _ in .init(ok: true, doneMs: nowMs) })

        // Each request is on disk before it runs.
        let startedFirst = try #require(saved.first)
        #expect(startedFirst.requests["r0"] != nil)
        #expect(startedFirst.requests["r0"]?.result == nil)

        // Relaunch from the ledger as it was while r0 ran.
        var relaunched = startedFirst
        var reran: [String] = []
        let after = await SyncManageFeed.apply(
            requests: requests, synced: [:], ledger: &relaunched, nowMs: nowMs + 1, save: { _ in },
            perform: { request in
                reran.append(request.id)
                return .init(ok: true, doneMs: nowMs + 1)
            })
        #expect(reran == ["r1"])
        #expect(after.results["r0"]?.error == "interrupted")
        #expect(after.results["r1"]?.ok == true)
    }

    @Test func resultsTheIPhoneAlreadyHasAreNotRunAgainAfterAnUpgrade() async {
        let nowMs = SyncHostedRunContract.nowMs()
        let requests = manageRequests(3, at: nowMs)
        let synced: [String: SyncDeviceFeedContract.ManageResult] = ["r0": .init(ok: true, doneMs: nowMs)]
        var ledger = SyncManageFeed.Ledger()
        var reran: [String] = []
        let outcome = await SyncManageFeed.apply(
            requests: requests, synced: synced, ledger: &ledger, nowMs: nowMs, save: { _ in },
            perform: { request in
                reran.append(request.id)
                return .init(ok: true, doneMs: nowMs)
            })
        #expect(reran == ["r1", "r2"])
        #expect(outcome.results["r0"] == synced["r0"])
    }

    @Test func expiredRequestsAreIgnoredAndOldLedgerEntriesPruned() async {
        let nowMs = SyncHostedRunContract.nowMs()
        let stale = SyncDeviceFeedContract.ManageRequest(
            id: "old", op: .createAgent, name: "Old", requestedMs: nowMs - SyncDeviceFeedContract.requestTTLMs - 1)
        var ledger = SyncManageFeed.Ledger(requests: [
            "ancient": .init(startedMs: nowMs - SyncManageFeed.Ledger.retentionMs - 1, result: .init(ok: true, doneMs: 0))
        ])
        let outcome = await SyncManageFeed.apply(
            requests: [stale], synced: [:], ledger: &ledger, nowMs: nowMs, save: { _ in },
            perform: { _ in
                Issue.record("an expired request ran")
                return .init(ok: true, doneMs: nowMs)
            })
        #expect(outcome.applied == 0)
        #expect(outcome.results.isEmpty)
        #expect(ledger.requests.isEmpty)
    }

    // MARK: - Default agent

    @Test func onlyTheDefaultAgentAmongBuiltInsCanBeHosted() {
        #expect(SyncHostRunner.canHost(.default))
        #expect(SyncHostRunner.canHost(Agent(name: "Mine")))
        #expect(!SyncHostRunner.canHost(Agent(name: "Helper", isBuiltIn: true)))
    }

    @Test func otherMacsDontOfferAHostsDefaultAgent() async throws {
        try await ChatHistoryTestStorage.run {
            let core = try SyncService.shared.open()
            defer { SyncService.shared.close() }
            let other = "other-device-\(UUID().uuidString)"
            let scope = try core.createConversation(title: "Agents on Other", replication: .synced)
            try core.setConversationTags(
                scope: scope,
                tags: [
                    Tag(key: SyncConversationMapper.TagKey.device, value: other),
                    Tag(key: SyncConversationMapper.TagKey.kind, value: SyncHostedRunContract.directoryKind),
                ].sorted { $0.key < $1.key }
            )
            func directory(_ agents: [SyncHostedRunContract.DirectoryEntry]) throws {
                try core.setConversationAppData(
                    scope: scope,
                    namespace: SyncHostedRunContract.directoryNamespace,
                    bytes: try SyncHostedRunContract.encode(
                        SyncHostedRunContract.Directory(device: other, agents: agents, updatedMs: SyncHostedRunContract.nowMs())
                    )
                )
            }
            let fallback = SyncHostedRunContract.DirectoryEntry(
                id: Agent.defaultId.uuidString.lowercased(),
                name: "Osaurus",
                isDefault: true
            )
            let device = Device(id: other, user: "u", name: "Other Mac", platform: "macos", lastSeenMs: 0, revoked: false, isSelf: false)
            try directory([fallback])
            #expect(SyncAgentDirectory.hosts(core: core, devices: [device]).isEmpty)

            let researcher = SyncHostedRunContract.DirectoryEntry(id: UUID().uuidString.lowercased(), name: "Researcher")
            try directory([fallback, researcher])
            let hosts = SyncAgentDirectory.hosts(core: core, devices: [device])
            #expect(hosts.first?.agents.map(\.name) == ["Researcher"])
        }
    }
}
