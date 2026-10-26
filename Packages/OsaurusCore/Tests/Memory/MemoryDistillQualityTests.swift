import Foundation
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

    @Test func realFactsThatMentionAbsenceSurvive() {
        for fact in [
            "User's name is Eric", "User is not available on weekends",
            "User wants no information shared with third parties", "User works at Unknown Worlds Entertainment",
            "User has no pets",
        ] {
            #expect(!MemoryDistillateScreen.isAbsenceStatement(fact), "\(fact)")
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
