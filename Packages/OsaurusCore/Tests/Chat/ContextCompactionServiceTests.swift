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

    // MARK: Token-aware acceptance (short-but-huge conversations)

    /// ~8k estimated tokens of content — well past `minimumCoveredTokens`.
    private var hugeText: String { String(repeating: "lorem ipsum dolor sit ", count: 1_500) }

    @Test("two huge exchanges fall back to cutting at the last user turn")
    func hugeTwoExchangeConversationIsCompactable() {
        // A pasted document + long answer, then a follow-up: the preferred
        // cut (second-from-last user turn) is index 0 and covers nothing,
        // but the first exchange alone is worth reclaiming.
        let turns = [
            ChatTurn(role: .user, content: hugeText),
            ChatTurn(role: .assistant, content: hugeText),
            ChatTurn(role: .user, content: "follow-up"),
            ChatTurn(role: .assistant, content: "short answer"),
        ]
        let cut = ContextCompactionService.compactionCutIndex(
            turns: turns, existingSummary: nil)
        #expect(cut == 2)
        #expect(turns[2].role == .user)
    }

    @Test("a huge span below the turn minimum passes on tokens")
    func hugeShortSpanPassesOnTokens() {
        // Three exchanges; the preferred cut covers only the first (2 turns,
        // below `minimumCoveredTurns`) but it is token-heavy.
        let turns = [
            ChatTurn(role: .user, content: hugeText),
            ChatTurn(role: .assistant, content: hugeText),
            ChatTurn(role: .user, content: "q1"),
            ChatTurn(role: .assistant, content: "a1"),
            ChatTurn(role: .user, content: "q2"),
            ChatTurn(role: .assistant, content: "a2"),
        ]
        let cut = ContextCompactionService.compactionCutIndex(
            turns: turns, existingSummary: nil)
        #expect(cut == 2)
    }

    @Test("a single huge exchange is covered whole (last-resort cut)")
    func singleHugeExchangeCoversWholeTranscript() {
        // A pasted document + one answered question: no user-turn cut can
        // cover anything, so the whole transcript becomes the covered span —
        // follow-up questions run against the summary.
        let turns = [
            ChatTurn(role: .user, content: hugeText),
            ChatTurn(role: .assistant, content: hugeText),
        ]
        #expect(
            ContextCompactionService.compactionCutIndex(
                turns: turns, existingSummary: nil) == turns.count)
    }

    @Test("token weight riding a document attachment counts toward the gate")
    func attachmentTokensCountTowardGate() {
        // The live repro: an 18-character question whose 200k tokens live in
        // an attached document, plus one assistant answer. The turn content
        // alone is tiny — the attachment must carry the size gate.
        let doc = Attachment(
            kind: .document(filename: "book.txt", content: hugeText, fileSize: hugeText.count)
        )
        let turns = [
            ChatTurn(role: .user, content: "what is this about", attachments: [doc]),
            ChatTurn(role: .assistant, content: "a short answer"),
        ]
        #expect(
            ContextCompactionService.compactionCutIndex(
                turns: turns, existingSummary: nil) == turns.count)
    }

    @Test("the last-resort cut requires a completed assistant reply")
    func lastResortRequiresAssistantTail() {
        // Mid-exchange (transcript ends on the user turn) nothing is covered.
        let turns = [ChatTurn(role: .user, content: hugeText)]
        #expect(
            ContextCompactionService.compactionCutIndex(
                turns: turns, existingSummary: nil) == nil)
    }

    @Test("a fully-covered transcript regrows into another whole cut only when heavy")
    func fullCoverageGrowsOnlyWhenNewSpanIsHeavy() {
        let first = [
            ChatTurn(role: .user, content: hugeText),
            ChatTurn(role: .assistant, content: hugeText),
        ]
        let existing = ConversationSummary(
            summaryText: "covers the document exchange",
            coveredTurnIds: first.map(\.id),
            modelIdentifier: "m",
            savedTokensEstimate: 1_000
        )
        // A small follow-up exchange is not worth another inference call…
        let smallGrowth =
            first + [
                ChatTurn(role: .user, content: "follow-up"),
                ChatTurn(role: .assistant, content: "answer"),
            ]
        #expect(
            ContextCompactionService.compactionCutIndex(
                turns: smallGrowth, existingSummary: existing) == nil)
        // …but a token-heavy one is, and the cut covers everything again.
        let heavyGrowth =
            first + [
                ChatTurn(role: .user, content: "another paste \(hugeText)"),
                ChatTurn(role: .assistant, content: "answer"),
            ]
        #expect(
            ContextCompactionService.compactionCutIndex(
                turns: heavyGrowth, existingSummary: existing) == heavyGrowth.count)
    }

    @Test("the fallback cut never erodes an existing summary's contract")
    func fallbackRespectsExistingSummary() {
        // Existing summary covers the huge first exchange; the preferred cut
        // (index 2) covers no MORE than the summary already does, and the
        // fallback must not fire just because the last user turn sits later.
        let turns = [
            ChatTurn(role: .user, content: hugeText),
            ChatTurn(role: .assistant, content: hugeText),
            ChatTurn(role: .user, content: "follow-up"),
            ChatTurn(role: .assistant, content: "answer"),
        ]
        let existing = ConversationSummary(
            summaryText: "covers the document exchange",
            coveredTurnIds: [turns[0].id, turns[1].id],
            modelIdentifier: "m",
            savedTokensEstimate: 1_000
        )
        #expect(
            ContextCompactionService.compactionCutIndex(
                turns: turns, existingSummary: existing) == nil)
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

    @Test("full-transcript coverage is valid; deletions and empties are not")
    func fullCoverageValidDeletionsNot() {
        let t = turns(4)
        let coveringAll = ConversationSummary(
            summaryText: "s",
            coveredTurnIds: t.map(\.id),
            modelIdentifier: "m",
            savedTokensEstimate: 0
        )
        // The whole-transcript last-resort cut produces exactly this state;
        // the next user message extends the transcript past the prefix.
        #expect(ContextCompactionService.summaryIsValid(coveringAll, for: t))

        // Deleting covered turns leaves the summary covering MORE than the
        // transcript holds — invalid.
        #expect(!ContextCompactionService.summaryIsValid(coveringAll, for: Array(t.prefix(3))))

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

    @Test("attached document text is fed to the summarizer, like the send path")
    func attachedDocumentContentIncluded() {
        // The send path prepends document text to the user message, so the
        // assistant's answers are grounded in it — the compaction transcript
        // must include it or a "pasted document + one question" chat
        // summarizes down to just the question.
        let doc = Attachment(
            kind: .document(
                filename: "novel.txt",
                content: "Lucy visits Florence and meets George.",
                fileSize: 38
            )
        )
        let covered = [
            ChatTurn(role: .user, content: "what is this about", attachments: [doc]),
            ChatTurn(role: .assistant, content: "a novel about Lucy"),
        ]
        let transcript = ContextCompactionService.renderTranscript(
            covered: covered, existingSummary: nil, charBudget: 100_000)
        #expect(transcript.contains("[User attached document \"novel.txt\"]"))
        #expect(transcript.contains("Lucy visits Florence and meets George."))
        #expect(transcript.contains("[User]: what is this about"))
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

// MARK: - Warm-up composition

/// Warm-up must serialize the identical post-compaction shape the send
/// composes (summary message in place of covered turns), or the prefill it
/// stores (KV + disk L2) diverges from the real send right after the system
/// prompt and every warmed byte past it is wasted.
@Suite("Compaction warm-up composition")
@MainActor
struct CompactionWarmupCompositionTests {

    private func makeSession(pairs: Int) -> (ChatSession, [ChatTurn]) {
        let session = ChatSession()
        var turns: [ChatTurn] = []
        for i in 0..<pairs {
            turns.append(ChatTurn(role: .user, content: "question \(i)"))
            turns.append(ChatTurn(role: .assistant, content: "answer \(i)"))
        }
        session.turns = turns
        return (session, turns)
    }

    @Test("warm-up injects the summary in place of covered turns, like the send")
    func warmupInjectsSummary() {
        let (session, turns) = makeSession(pairs: 4)
        let summary = ConversationSummary(
            summaryText: "the early exchanges",
            coveredTurnIds: turns[0..<4].map(\.id),
            modelIdentifier: "m",
            savedTokensEstimate: 100
        )
        session.conversationSummary = summary

        let msgs = session.buildWarmupMessages(systemPrompt: "sys")
        // system + one summary message + the 4 surviving turns.
        #expect(msgs.count == 6)
        #expect(msgs[0].role == "system")
        #expect(msgs[1].role == "user")
        #expect(msgs[1].content == summary.contextMessageText)
        #expect(msgs[2].content == "question 2")
        // Covered turn content never rides alongside the summary.
        #expect(!msgs.contains { $0.content?.contains("question 0") == true })
        #expect(!msgs.contains { $0.content?.contains("answer 1") == true })
    }

    @Test("a summary that no longer matches the transcript is ignored")
    func invalidSummaryIgnored() {
        let (session, turns) = makeSession(pairs: 3)
        let summary = ConversationSummary(
            summaryText: "stale",
            coveredTurnIds: [UUID(), UUID()],
            modelIdentifier: "m",
            savedTokensEstimate: 0
        )
        session.conversationSummary = summary

        #expect(session.activeWarmupSummary == nil)
        let msgs = session.buildWarmupMessages(systemPrompt: "sys")
        #expect(msgs.count == 1 + turns.count)
        #expect(!msgs.contains { $0.content == summary.contextMessageText })
    }

    @Test("without a summary the full history is warmed")
    func noSummaryFullHistory() {
        let (session, turns) = makeSession(pairs: 3)
        let msgs = session.buildWarmupMessages(systemPrompt: "sys")
        #expect(msgs.count == 1 + turns.count)
        #expect(msgs[1].content == "question 0")
    }
}
