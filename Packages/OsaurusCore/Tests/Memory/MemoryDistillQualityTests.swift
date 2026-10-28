import Foundation
import OsaurusSQLCipher
import Testing

@testable import OsaurusCore

/// Distillate quality on the shapes the bb10 native replay left in its memory
/// DB (`handoff-20261026T0926Z/memory.sqlite`): a user's one-off instruction
/// pinned verbatim, identity "facts" that only say a fact is missing, and
/// function-word FTS matches that recalled the instruction for an unrelated
/// question.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MemoryDistillQualityTests {
    /// Verbatim pinned fact 10924993… (episode 37) from the replay DB.
    private static let staleInstruction =
        "Use file_read to read probe.json in the working folder. Return its current value without modifying any file."

    // MARK: - Screen

    @Test func verbatimUserTurnIsNotPinnedButRestatedFactsAre() {
        let parsed = MemoryService.DistillResult(
            pinnedCandidates: [
                .init(content: Self.staleInstruction, salience: 0.8, tags: []),
                .init(content: "  use FILE_READ to read probe.json in the working folder.  return its current value without modifying any file  ", salience: 0.8, tags: []),
                .init(content: "User prefers metric units.", salience: 0.7, tags: ["preference"]),
            ])
        let screened = MemoryDistillateScreen.screen(
            parsed, userMessages: [Self.staleInstruction, "I prefer metric units"])
        #expect(screened.pinnedCandidates.map(\.content) == ["User prefers metric units."])
    }

    @Test func absenceStatementsFromTheReplayAreRejected() {
        for fact in [
            "User's name is not specified", "User works at not specified", "No identity-relevant facts found",
            "No identity facts found", "Unknown", "N/A", "User's location is unknown",
        ] {
            #expect(MemoryDistillateScreen.isAbsenceStatement(fact), "\(fact)")
        }
    }

    @Test func verbatimDurableStatementsAndPreferencesRemainPinned() {
        let facts = [
            "My sailboat is named Peregrine Dusk.",
            "My name is Eric.",
            "I prefer metric units.",
            "Use metric units for measurements.",
        ]
        let parsed = MemoryService.DistillResult(pinnedCandidates: facts.map {
            .init(content: $0, salience: 0.7, tags: [])
        })
        let screened = MemoryDistillateScreen.screen(parsed, userMessages: facts)
        #expect(screened.pinnedCandidates.map(\.content) == facts)
        #expect(MemoryDistillateScreen.screen(
            .init(pinnedCandidates: [.init(content: Self.staleInstruction, salience: 0.8, tags: [])]),
            userMessages: [Self.staleInstruction]
        ).pinnedCandidates.isEmpty)
    }

    @Test func realFactsThatMentionAbsenceSurvive() {
        for fact in [
            "User's name is Eric", "User is not available on weekends",
            "User wants no information shared with third parties", "User works at Unknown Worlds Entertainment",
            "User has no pets",
            "User wants their salary not disclosed to coworkers",
            "User prefers forms where optional information is not provided",
            "User studies reports about no identity facts found",
        ] {
            #expect(!MemoryDistillateScreen.isAbsenceStatement(fact), "\(fact)")
        }
    }

    @Test func failedDelegatedMarkerWriteDoesNotEnqueueUserAttributedSignal() async throws {
        try await ChatHistoryTestStorage.run {
            MemoryConfigurationStore.invalidateCache()
            MemoryDatabase.shared.close()
            try MemoryDatabase.shared.open()
            defer {
                MemoryDatabase.shared.close()
                MemoryConfigurationStore.invalidateCache()
            }
            var config = MemoryConfiguration.default
            config.enabled = true
            config.extractionMode = .manual
            MemoryConfigurationStore.save(config)
            let connection = try OsaurusStorageOpener.open(path: OsaurusPaths.memoryDatabaseFile().path)
            defer { sqlite3_close(connection) }
            let trigger = """
                CREATE TRIGGER reject_delegated_marker BEFORE INSERT ON delegated_conversations
                BEGIN SELECT RAISE(ABORT, 'controlled delegated marker failure'); END;
                """
            try #require(sqlite3_exec(connection, trigger, nil, nil, nil) == SQLITE_OK)
            let conversation = UUID().uuidString
            let agent = UUID().uuidString
            let before = await MemoryService.shared.bufferTelemetry()
            await MemoryService.shared.bufferTurn(userMessage: "Delegating agent instructions",
                assistantMessage: "Worker result", agentId: agent, conversationId: conversation,
                provenance: .delegated)
            #expect(try MemoryDatabase.shared.loadPendingSignals(conversationId: conversation).isEmpty)
            #expect(try !MemoryDatabase.shared.isDelegatedConversation(conversation))
            #expect(await MemoryService.shared.activeConversationId(forAgent: agent) == nil)
            let after = await MemoryService.shared.bufferTelemetry()
            #expect(after.insertFailures == before.insertFailures + 1)
            try #require(sqlite3_exec(connection, "DROP TRIGGER reject_delegated_marker", nil, nil, nil) == SQLITE_OK)
            // Positive control: the same common buffer accepts a normal user
            // turn once marker failure has prevented the delegated enqueue.
            await MemoryService.shared.bufferTurn(userMessage: "My own statement",
                assistantMessage: "Noted", agentId: agent, conversationId: conversation)
            #expect(try MemoryDatabase.shared.loadPendingSignals(conversationId: conversation).count == 1)
        }
    }

    // MARK: - Every sink sees the screened distillate

    /// Drives the real `flushSessionAndWait` → `performDistillSession` path
    /// with a scripted core-model reply, in a project chat, so the agent's
    /// pinned facts, the project mirror and identity are all written by
    /// production code from one distillate.
    @Test func agentProjectMirrorAndIdentityReceiveTheSameScreenedDistillate() async throws {
        try await ChatHistoryTestStorage.run {
            MemoryConfigurationStore.invalidateCache()
            MemoryDatabase.shared.close()
            try MemoryDatabase.shared.openInMemory()
            var memoryConfig = MemoryConfiguration.default
            memoryConfig.enabled = true
            MemoryConfigurationStore.save(memoryConfig)
            var chatConfig = ChatConfigurationStore.load()
            let previousCoreName = chatConfig.coreModelName
            let previousCoreProvider = chatConfig.coreModelProvider
            chatConfig.coreModelName = "fixture-distiller"
            chatConfig.coreModelProvider = nil
            ChatConfigurationStore.save(chatConfig)
            defer {
                var restore = ChatConfigurationStore.load()
                restore.coreModelName = previousCoreName
                restore.coreModelProvider = previousCoreProvider
                ChatConfigurationStore.save(restore)
                MemoryDatabase.shared.close()
                MemoryConfigurationStore.invalidateCache()
            }
            try #require(!AgentManager.shared.effectiveMemoryDisabled(for: Agent.defaultId))

            let reply = """
                {"episode": {"summary": "The user had the assistant read probe.json and stated a unit preference.", \
                "topics": ["probe.json"], "decisions": [], "action_items": [], "salience": 0.5}, \
                "entities": ["probe.json"], \
                "pinned_candidates": [{"content": "\(Self.staleInstruction)", "salience": 0.8, "tags": []}, \
                {"content": "User prefers metric units.", "salience": 0.7, "tags": ["preference"]}], \
                "identity_facts": ["User's name is not specified", "No identity facts found", "User's name is Eric"]}
                """
            // Control: the scripted reply really carries the rejected shapes,
            // so the assertions below cannot pass on an empty distillate.
            let unscreened = MemoryService.shared.parseDistillResponse(reply)
            try #require(unscreened.pinnedCandidates.count == 2)
            try #require(unscreened.identityFacts.count == 3)

            await MemoryService.shared.setDistillGenerateOverrideForTests { _, _ in reply }
            defer { Task { await MemoryService.shared.setDistillGenerateOverrideForTests(nil) } }

            let agentKey = Agent.defaultId.uuidString
            let conversationId = UUID().uuidString
            let projectId = UUID()
            await MemoryService.shared.bufferTurn(
                userMessage: Self.staleInstruction,
                assistantMessage: "probe.json holds 45.",
                agentId: agentKey, conversationId: conversationId, projectId: projectId)
            await MemoryService.shared.bufferTurn(
                userMessage: "Also, I prefer metric units for anything you measure.",
                assistantMessage: "Noted, metric units from now on.",
                agentId: agentKey, conversationId: conversationId, projectId: projectId)

            let outcome = await MemoryService.shared.flushSessionAndWait(
                agentId: agentKey, conversationId: conversationId)
            try #require(outcome.episodeId != nil, "distill did not produce an episode: \(outcome)")

            let agentFacts = try MemoryDatabase.shared.loadPinnedFacts(agentId: agentKey).map(\.content)
            let projectFacts = try MemoryDatabase.shared.loadPinnedFacts(
                agentId: MemoryNamespace.project(projectId).key).map(\.content)
            #expect(agentFacts == ["User prefers metric units."])
            #expect(projectFacts == ["User prefers metric units."])
            let identity = try #require(try MemoryDatabase.shared.loadIdentity())
            #expect(identity.overrides == ["User's name is Eric"])
        }
    }

    /// The replay's worker session (agent 8129DE06…) distilled "User's token
    /// is BG_TOKEN_9 within the delegated task context" into the global
    /// identity at 10:41:08Z. A delegated session's requester is an agent.
    @Test func delegatedSessionNeverWritesTheUsersIdentity() async throws {
        try await ChatHistoryTestStorage.run {
            MemoryConfigurationStore.invalidateCache()
            MemoryDatabase.shared.close()
            try MemoryDatabase.shared.openInMemory()
            var memoryConfig = MemoryConfiguration.default
            memoryConfig.enabled = true
            MemoryConfigurationStore.save(memoryConfig)
            var chatConfig = ChatConfigurationStore.load()
            let previousCoreName = chatConfig.coreModelName
            let previousCoreProvider = chatConfig.coreModelProvider
            chatConfig.coreModelName = "fixture-distiller"
            chatConfig.coreModelProvider = nil
            ChatConfigurationStore.save(chatConfig)
            defer {
                var restore = ChatConfigurationStore.load()
                restore.coreModelName = previousCoreName
                restore.coreModelProvider = previousCoreProvider
                ChatConfigurationStore.save(restore)
                MemoryDatabase.shared.close()
                MemoryConfigurationStore.invalidateCache()
            }
            try #require(!AgentManager.shared.effectiveMemoryDisabled(for: Agent.defaultId))

            let reply = """
                {"episode": {"summary": "A delegated task returned BG_TOKEN_9.", "topics": [], "decisions": [], \
                "action_items": [], "salience": 0.4}, "entities": [], \
                "pinned_candidates": [{"content": "Delegated runs return the literal token they are asked for.", \
                "salience": 0.6, "tags": []}], \
                "identity_facts": ["User's token is BG_TOKEN_9 within the delegated task context"]}
                """
            let prompts = PromptCapture()
            await MemoryService.shared.setDistillGenerateOverrideForTests { prompt, _ in
                await prompts.record(prompt)
                return reply
            }
            defer { Task { await MemoryService.shared.setDistillGenerateOverrideForTests(nil) } }

            let agentKey = Agent.defaultId.uuidString
            let delegatedConversation = UUID().uuidString
            await MemoryService.shared.bufferDelegatedTurn(
                userMessage: "Return exactly BG_TOKEN_9 and nothing else. This is a delegated proof task.",
                assistantMessage: "BG_TOKEN_9",
                agentId: agentKey, conversationId: delegatedConversation)
            try #require(try MemoryDatabase.shared.isDelegatedConversation(delegatedConversation))

            let outcome = await MemoryService.shared.flushSessionAndWait(
                agentId: agentKey, conversationId: delegatedConversation)
            try #require(outcome.episodeId != nil, "distill did not produce an episode: \(outcome)")
            // The worker still learns from its own run.
            #expect(try MemoryDatabase.shared.loadPinnedFacts(agentId: agentKey).map(\.content)
                == ["Delegated runs return the literal token they are asked for."])
            #expect((try MemoryDatabase.shared.loadIdentity())?.overrides ?? [] == [])
            let prompt = try #require(await prompts.all.last)
            #expect(prompt.contains("\nDelegating agent: Return exactly BG_TOKEN_9"))
            #expect(!prompt.contains("\nUser: "))

            // Control: the same reply from the user's own session does write
            // identity, so the empty identity above is the delegated gate.
            let userConversation = UUID().uuidString
            await MemoryService.shared.bufferTurn(
                userMessage: "Return exactly BG_TOKEN_9 and nothing else. This is my own proof task.",
                assistantMessage: "BG_TOKEN_9",
                agentId: agentKey, conversationId: userConversation)
            _ = await MemoryService.shared.flushSessionAndWait(agentId: agentKey, conversationId: userConversation)
            #expect((try MemoryDatabase.shared.loadIdentity())?.overrides
                == ["User's token is BG_TOKEN_9 within the delegated task context"])
            #expect(try !MemoryDatabase.shared.isDelegatedConversation(userConversation))
        }
    }

    private actor PromptCapture {
        private(set) var all: [String] = []
        func record(_ prompt: String) { all.append(prompt) }
    }

    // MARK: - FTS recall terms

    @Test func functionWordsNoLongerRecallAnUnrelatedInstruction() throws {
        let db = MemoryDatabase()
        try db.openInMemory()
        defer { db.close() }
        try db.insertPinnedFact(PinnedFact(agentId: "a", content: Self.staleInstruction, salience: 0.8))
        try db.insertPinnedFact(PinnedFact(agentId: "a", content: "The user's sailboat is named Peregrine Dusk.", salience: 0.6))

        // "the", "of" and "is" used to OR-match the instruction.
        #expect(try db.searchPinnedFactsText(query: "What is the capital of France?", agentId: "a").isEmpty)
        // Content words still recall, with function words around them.
        let boat = try db.searchPinnedFactsText(query: "What is the name of my boat?", agentId: "a")
        #expect(boat.map(\.content) == ["The user's sailboat is named Peregrine Dusk."])
    }

    @Test func memoryAndKnowledgeDropTheSameFunctionWords() {
        #expect(MemoryDatabase.ftsMatchQuery("What is the capital of France?") == "\"capital\"* OR \"France\"*")
        #expect(KnowledgeDatabase.ftsMatchQuery("What is the capital of France?") == "\"capital\"* OR \"France\"*")
        // A query made only of function words keeps them, so it still matches.
        #expect(MemoryDatabase.ftsMatchQuery("to be or not") == "\"to\"* OR \"be\"* OR \"or\"* OR \"not\"*")
    }
}
