//
//  ContextCompactionServiceTests.swift
//  osaurusTests
//
//  Deterministic contracts for LLM context compaction: configuration
//  round-trips for the new compaction-model fields, boundary selection
//  (`compactionCutIndex`), summary validation against the live transcript
//  (`summaryIsValid`), transcript rendering for the summarization prompt,
//  and `ConversationSummary` persistence inside `ChatSessionData`.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Configuration fields

@Suite("Compaction model configuration")
struct CompactionModelConfigurationTests {

    @Test("identifier composes provider/name and is nil when unset")
    func identifierComposition() {
        var cfg = ChatConfiguration.default
        #expect(cfg.compactionModelIdentifier == nil)

        cfg.compactionModelName = "qwen3-4b"
        #expect(cfg.compactionModelIdentifier == "qwen3-4b")

        cfg.compactionModelProvider = "openai"
        cfg.compactionModelName = "gpt-4o-mini"
        #expect(cfg.compactionModelIdentifier == "openai/gpt-4o-mini")

        cfg.compactionModelName = ""
        #expect(cfg.compactionModelIdentifier == nil)
    }

    @Test("Codable round-trip preserves the compaction model fields")
    func codableRoundTrip() throws {
        var cfg = ChatConfiguration.default
        cfg.compactionModelProvider = "anthropic"
        cfg.compactionModelName = "claude-haiku"
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        #expect(decoded.compactionModelProvider == "anthropic")
        #expect(decoded.compactionModelName == "claude-haiku")
        #expect(decoded.compactionModelIdentifier == "anthropic/claude-haiku")
    }

    @Test("legacy JSON without compaction keys decodes to unset")
    func legacyDecode() throws {
        let data = try JSONEncoder().encode(ChatConfiguration.default)
        var object =
            try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "compactionModelProvider")
        object.removeValue(forKey: "compactionModelName")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: legacy)
        #expect(decoded.compactionModelProvider == nil)
        #expect(decoded.compactionModelName == nil)
        #expect(decoded.compactionModelIdentifier == nil)
    }
}

// MARK: - Boundary selection

@Suite("Compaction cut index")
@MainActor
struct CompactionCutIndexTests {

    /// Alternating user/assistant conversation with `pairs` exchanges.
    private func conversation(pairs: Int) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        for i in 0..<pairs {
            turns.append(ChatTurn(role: .user, content: "question \(i)"))
            turns.append(ChatTurn(role: .assistant, content: "answer \(i)"))
        }
        return turns
    }

    @Test("cut lands on the second-from-last user turn")
    func cutOnSecondFromLastUserTurn() {
        let turns = conversation(pairs: 5)  // user indices 0,2,4,6,8
        let cut = ContextCompactionService.compactionCutIndex(
            turns: turns, existingSummary: nil)
        #expect(cut == 6)
        // Everything before the cut is a completed exchange; the cut itself
        // is a user turn, so no assistant/tool pair is ever split.
        #expect(turns[6].role == .user)
    }

    @Test("too-short conversations have nothing to compact")
    func shortConversationReturnsNil() {
        #expect(
            ContextCompactionService.compactionCutIndex(
                turns: conversation(pairs: 2), existingSummary: nil) == nil)
        #expect(
            ContextCompactionService.compactionCutIndex(
                turns: [], existingSummary: nil) == nil)
        // One user turn only — fewer than recentUserTurnsToKeep.
        #expect(
            ContextCompactionService.compactionCutIndex(
                turns: [ChatTurn(role: .user, content: "hi")], existingSummary: nil) == nil)
    }

    @Test("an existing summary must grow, or there is nothing to compact")
    func existingSummaryMustGrow() {
        let turns = conversation(pairs: 5)
        // Existing summary already covers turns[0..<6] — the same span a new
        // run would pick, so compaction is a no-op.
        let existing = ConversationSummary(
            summaryText: "old summary",
            coveredTurnIds: Array(turns.prefix(6)).map(\.id),
            modelIdentifier: "m",
            savedTokensEstimate: 100
        )
        #expect(
            ContextCompactionService.compactionCutIndex(
                turns: turns, existingSummary: existing) == nil)

        // Two more exchanges later, the cut moves past the covered span and
        // compaction becomes possible again.
        let grown = turns + conversation(pairs: 2)
        let cut = ContextCompactionService.compactionCutIndex(
            turns: grown, existingSummary: existing)
        #expect(cut == 10)
    }
}

// MARK: - Summary validation

@Suite("Summary validation against the live transcript")
@MainActor
struct SummaryValidationTests {

    private func turns(_ count: Int) -> [ChatTurn] {
        (0..<count).map { i in
            ChatTurn(role: i % 2 == 0 ? .user : .assistant, content: "t\(i)")
        }
    }

    @Test("valid when covered ids are exactly the transcript prefix")
    func validPrefix() {
        let t = turns(8)
        let summary = ConversationSummary(
            summaryText: "s",
            coveredTurnIds: t.prefix(4).map(\.id),
            modelIdentifier: "m",
            savedTokensEstimate: 0
        )
        #expect(ContextCompactionService.summaryIsValid(summary, for: t))
    }

    @Test("invalid when a covered turn was edited/regenerated (id changed)")
    func invalidAfterEdit() {
        var t = turns(8)
        let summary = ConversationSummary(
            summaryText: "s",
            coveredTurnIds: t.prefix(4).map(\.id),
            modelIdentifier: "m",
            savedTokensEstimate: 0
        )
        // Regeneration replaces the turn (new id) at a covered position.
        t[2] = ChatTurn(role: .user, content: "edited")
        #expect(!ContextCompactionService.summaryIsValid(summary, for: t))
    }

    @Test("invalid when covered turns were deleted or cover everything")
    func invalidWhenDeletedOrTotal() {
        let t = turns(4)
        let coveringAll = ConversationSummary(
            summaryText: "s",
            coveredTurnIds: t.map(\.id),
            modelIdentifier: "m",
            savedTokensEstimate: 0
        )
        // A summary must leave at least one live turn uncovered.
        #expect(!ContextCompactionService.summaryIsValid(coveringAll, for: t))

        let empty = ConversationSummary(
            summaryText: "s", coveredTurnIds: [], modelIdentifier: "m", savedTokensEstimate: 0)
        #expect(!ContextCompactionService.summaryIsValid(empty, for: t))
    }
}

// MARK: - Transcript rendering

@Suite("Compaction transcript rendering")
@MainActor
struct CompactionTranscriptTests {

    @Test("renders role-labelled lines and folds in an earlier summary")
    func rendersRolesAndExistingSummary() {
        let covered = [
            ChatTurn(role: .user, content: "please do X"),
            ChatTurn(role: .assistant, content: "done X"),
        ]
        let existing = ConversationSummary(
            summaryText: "earlier things happened",
            coveredTurnIds: [UUID()],
            modelIdentifier: "m",
            savedTokensEstimate: 0
        )
        let transcript = ContextCompactionService.renderTranscript(
            covered: covered, existingSummary: existing, charBudget: 100_000)
        #expect(transcript.contains("[Summary of even earlier conversation]"))
        #expect(transcript.contains("earlier things happened"))
        #expect(transcript.contains("[User]: please do X"))
        #expect(transcript.contains("[Assistant]: done X"))
    }

    @Test("turns already covered by the earlier summary are not re-fed")
    func previouslyCoveredTurnsSkipped() {
        let old = ChatTurn(role: .user, content: "ancient request")
        let newer = ChatTurn(role: .user, content: "newer request")
        let existing = ConversationSummary(
            summaryText: "covers the earliest exchange",
            coveredTurnIds: [old.id],
            modelIdentifier: "m",
            savedTokensEstimate: 0
        )
        let transcript = ContextCompactionService.renderTranscript(
            covered: [old, newer], existingSummary: existing, charBudget: 100_000)
        #expect(!transcript.contains("ancient request"))
        #expect(transcript.contains("newer request"))
    }

    @Test("over-budget transcripts keep head and tail with an omission marker")
    func clipsToCharBudget() {
        let covered = (0..<200).map { i in
            ChatTurn(
                role: i % 2 == 0 ? .user : .assistant,
                content: String(repeating: "word\(i) ", count: 40))
        }
        let budget = 2_000
        let transcript = ContextCompactionService.renderTranscript(
            covered: covered, existingSummary: nil, charBudget: budget)
        #expect(transcript.contains("[… middle of excerpt omitted for length …]"))
        // Head (the original task) and tail (most recent context) survive.
        #expect(transcript.contains("word0"))
        #expect(transcript.contains("word199"))
        // Budget plus the omission marker line is the ceiling.
        #expect(transcript.count <= budget + 60)
    }
}

// MARK: - Persistence

@Suite("ConversationSummary persistence")
struct ConversationSummaryPersistenceTests {

    @Test("ChatSessionData round-trips the summary")
    func sessionDataRoundTrip() throws {
        let summary = ConversationSummary(
            summaryText: "the gist",
            coveredTurnIds: [UUID(), UUID()],
            modelIdentifier: "openai/gpt-4o-mini",
            savedTokensEstimate: 1234
        )
        let session = ChatSessionData(conversationSummary: summary)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ChatSessionData.self, from: data)
        #expect(decoded.conversationSummary == summary)
    }

    @Test("legacy sessions without the key decode to nil")
    func legacySessionDecodesNil() throws {
        let data = try JSONEncoder().encode(ChatSessionData())
        let decoded = try JSONDecoder().decode(ChatSessionData.self, from: data)
        #expect(decoded.conversationSummary == nil)
    }

    @Test("context message text embeds the summary body and framing")
    func contextMessageText() {
        let summary = ConversationSummary(
            summaryText: "key facts here",
            coveredTurnIds: [UUID()],
            modelIdentifier: "m",
            savedTokensEstimate: 0
        )
        #expect(summary.contextMessageText.contains("key facts here"))
        #expect(summary.contextMessageText.contains("Conversation summary"))
    }
}
