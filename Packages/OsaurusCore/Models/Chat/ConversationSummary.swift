//
//  ConversationSummary.swift
//  osaurus
//
//  Non-destructive LLM context compaction result for a chat session.
//
//  When a conversation outgrows the context window, the user (or the
//  auto-trigger) can run LLM compaction: a configured compaction model
//  summarizes the older portion of the conversation, and this summary
//  replaces the covered turns in the OUTBOUND message array only. The
//  visible transcript is never rewritten — the covered turns stay on
//  screen, with a marker showing where the summary boundary sits.
//

import Foundation

/// A frozen summary of the oldest turns of a chat session, produced by the
/// configured compaction model. Persisted with the session so compaction
/// survives relaunch.
public struct ConversationSummary: Codable, Equatable, Sendable {
    public let id: UUID
    /// The model-produced summary text (without the framing envelope —
    /// see `contextMessageText`).
    public let summaryText: String
    /// IDs of the turns this summary replaces, in transcript order. Always a
    /// contiguous prefix of the session's turns at creation time; validated
    /// against the live transcript before every use (see
    /// `covers(turns:)`) so edits/regenerations of covered turns
    /// invalidate the summary instead of silently misrepresenting history.
    public let coveredTurnIds: [UUID]
    public let createdAt: Date
    /// Identifier of the model that produced the summary (for Insights /
    /// the transcript marker).
    public let modelIdentifier: String
    /// Estimated tokens reclaimed: covered-turn cost minus the injected
    /// summary message cost, at creation time.
    public let savedTokensEstimate: Int

    public init(
        id: UUID = UUID(),
        summaryText: String,
        coveredTurnIds: [UUID],
        createdAt: Date = Date(),
        modelIdentifier: String,
        savedTokensEstimate: Int
    ) {
        self.id = id
        self.summaryText = summaryText
        self.coveredTurnIds = coveredTurnIds
        self.createdAt = createdAt
        self.modelIdentifier = modelIdentifier
        self.savedTokensEstimate = savedTokensEstimate
    }

    /// The exact message body injected into the outbound context in place of
    /// the covered turns. Byte-stable for the summary's lifetime so the
    /// paged-KV prefix over it can be reused across iterations/turns.
    public var contextMessageText: String {
        """
        [Conversation summary — earlier messages were compacted to fit the context window. \
        The full transcript remains visible to the user; you see this condensed version.]

        \(summaryText)

        [End of summary. Details above are condensed — if you need exact file contents, \
        tool output, or specifics, re-fetch them or ask the user rather than recalling \
        from memory.]
        """
    }
}
