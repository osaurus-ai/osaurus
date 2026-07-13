//
//  MemoryRecallEvaluator.swift
//  OsaurusCore
//
//  Driver for the `memory` eval domain. Seeds the (isolated) memory
//  store through the same `MemoryDatabase` writes the production
//  distiller lands, then runs a multi-turn chat where every turn goes
//  through the REAL read path: relevance gate → planner →
//  `assembleMemorySection` → `injectMemoryPrefix` onto the user message
//  — the exact bytes the chat surface injects. The transcript records
//  whether memory was actually injected per turn, so cases can score
//  both the plumbing (injection happened) and the behavior (the model
//  used it).
//
//  Lives in OsaurusCore because the composer's memory assembly and the
//  streaming hint decoders are internal runtime surface.
//

import Foundation

/// One completed turn of a memory-recall run.
public struct MemoryRecallTurn: Sendable, Codable {
    /// The visible answer for the turn.
    public let visibleText: String
    /// Whether a non-empty memory section was injected into this turn's
    /// user message (gate said yes AND the store had content).
    public let memoryInjected: Bool
    /// The injected memory section (for forensics on failing cases).
    public let memorySection: String?

    public init(visibleText: String, memoryInjected: Bool, memorySection: String?) {
        self.visibleText = visibleText
        self.memoryInjected = memoryInjected
        self.memorySection = memorySection
    }
}

/// Result of a memory-recall run.
public struct MemoryRecallTranscript: Sendable, Codable {
    public let turns: [MemoryRecallTurn]
    /// Non-nil when a turn failed; completed turns are kept.
    public let error: String?

    public init(turns: [MemoryRecallTurn], error: String? = nil) {
        self.turns = turns
        self.error = error
    }
}

/// Driver for the `memory` eval domain. MainActor because engine
/// construction and config-store reads are main-actor-isolated.
@MainActor
public enum MemoryRecallEvaluator {

    /// Episode seed shape (mirrors the case-file schema; kept here so the
    /// evals kit doesn't need the full `Episode` model).
    public struct EpisodeSeedInput: Sendable {
        public let summary: String
        public let topicsCSV: String
        public let entitiesCSV: String

        public init(summary: String, topicsCSV: String = "", entitiesCSV: String = "") {
            self.summary = summary
            self.topicsCSV = topicsCSV
            self.entitiesCSV = entitiesCSV
        }
    }

    /// Seed the shared (isolated-root) memory store for `agentId`. Writes
    /// go through the same `MemoryDatabase` inserts the production
    /// distiller uses, so the read path exercised by `run` is authentic.
    /// Identity overrides are GLOBAL in the store — pair every case with
    /// `reset()` so they can't bleed into the next case.
    public static func seed(
        agentId: String,
        pinnedFacts: [String] = [],
        episodes: [EpisodeSeedInput] = [],
        identityOverrides: [String] = []
    ) throws {
        let db = MemoryDatabase.shared
        try db.open()
        let now = ISO8601DateFormatter().string(from: Date())
        for fact in pinnedFacts {
            try db.insertPinnedFact(
                PinnedFact(
                    agentId: agentId,
                    content: fact,
                    salience: 0.9,
                    lastUsed: now,
                    createdAt: now
                )
            )
        }
        for episode in episodes {
            _ = try db.insertEpisode(
                Episode(
                    agentId: agentId,
                    conversationId: UUID().uuidString,
                    summary: episode.summary,
                    topicsCSV: episode.topicsCSV,
                    entitiesCSV: episode.entitiesCSV,
                    salience: 0.9,
                    conversationAt: now
                )
            )
        }
        for override in identityOverrides {
            try db.appendIdentityOverride(override)
        }
    }

    /// Clear the global identity overrides and the assembler's TTL cache
    /// so one case's seeds can never satisfy the next case's assertions.
    /// Per-agent rows (facts/episodes) are isolated by the unique agent id
    /// each case uses, so they don't need wiping.
    public static func reset() async {
        if let identity = try? MemoryDatabase.shared.loadIdentity(), !identity.overrides.isEmpty {
            for index in stride(from: identity.overrides.count - 1, through: 0, by: -1) {
                try? MemoryDatabase.shared.removeIdentityOverride(at: index)
            }
        }
        await MemoryContextAssembler.shared.invalidateCache()
    }

    /// Run `queries` as consecutive user turns of ONE conversation with
    /// per-turn memory injection — assemble via the production
    /// `assembleMemorySection` (gate + planner + budget) and prepend via
    /// `injectMemoryPrefix`, exactly like the chat surface.
    public static func run(
        queries: [String],
        agentId: String,
        model: String? = nil,
        maxTokens: Int = 512
    ) async -> MemoryRecallTranscript {
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        let engine = ChatEngine()
        let sessionId = UUID().uuidString

        var history: [ChatMessage] = []
        var turns: [MemoryRecallTurn] = []

        for query in queries {
            history.append(ChatMessage(role: "user", content: query))

            let memorySection = await SystemPromptComposer.assembleMemorySection(
                agentId: agentId,
                query: query
            )
            var messages = history
            SystemPromptComposer.injectMemoryPrefix(memorySection, into: &messages)

            let request = ChatCompletionRequest(
                model: resolvedModel,
                messages: messages,
                temperature: 0.0,
                max_tokens: maxTokens,
                stream: true,
                top_p: nil,
                frequency_penalty: nil,
                presence_penalty: nil,
                stop: nil,
                n: nil,
                tools: nil,
                tool_choice: nil,
                session_id: sessionId
            )

            var visible = ""
            var reasoning = ""
            do {
                let stream = try await engine.streamChat(request: request)
                for try await delta in stream {
                    if let fragment = StreamingReasoningHint.decode(delta) {
                        reasoning += fragment
                        continue
                    }
                    if StreamingStatsHint.decode(delta) != nil { continue }
                    if StreamingToolHint.isSentinel(delta) { continue }
                    visible += delta
                }
            } catch {
                return MemoryRecallTranscript(
                    turns: turns,
                    error: "turn \(turns.count + 1)/\(queries.count) failed: \(error)"
                )
            }

            turns.append(
                MemoryRecallTurn(
                    visibleText: visible,
                    memoryInjected: !(memorySection ?? "").trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty,
                    memorySection: memorySection
                )
            )
            // History keeps the RAW user text (memory prefix is per-turn,
            // recomputed each send — matching the chat surface's frozen-
            // prefix behavior closely enough for eval purposes).
            history.append(
                ChatMessage(
                    role: "assistant",
                    content: visible.isEmpty ? nil : visible,
                    tool_calls: nil,
                    tool_call_id: nil,
                    reasoning_content: reasoning.isEmpty ? nil : reasoning
                )
            )
        }

        return MemoryRecallTranscript(turns: turns)
    }
}
