//
//  ContextCompactionService.swift
//  osaurus
//
//  LLM-powered context compaction for chat sessions.
//
//  When a conversation outgrows the context window, this service asks the
//  user-configured compaction model (Settings → Chat → Compaction Model)
//  to summarize the oldest turns. The result is a `ConversationSummary`
//  that replaces the covered turns in the OUTBOUND message array only —
//  the visible transcript is never rewritten. The deterministic trimmer
//  (`ContextBudgetManager` + `CompactionWatermark`) remains the safety net
//  beneath this: it still runs on whatever the summary didn't reclaim.
//
//  Unlike `CoreModelService` there is deliberately NO chat-model fallback:
//  when no compaction model is configured, callers surface a first-run
//  dialog that asks the user to pick one (remote models allowed — they
//  pass through the Privacy Filter via `RemoteProviderService`).
//

import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "context_compaction")

// MARK: - Errors / phases / UI state

enum ContextCompactionError: Error, LocalizedError, Equatable {
    /// No compaction model configured — the caller should open the
    /// first-run model-selection dialog rather than silently falling back.
    case needsModelSelection
    /// A model is configured but the router can't serve it right now.
    case modelUnavailable(String)
    /// The conversation is too short (or already fully covered by an
    /// existing summary) for compaction to reclaim anything.
    case nothingToCompact
    /// The model returned an empty/blank summary.
    case emptySummary
    case timedOut

    var errorDescription: String? {
        switch self {
        case .needsModelSelection:
            return "No compaction model is configured"
        case .modelUnavailable(let model):
            return "Compaction model '\(model)' is not available"
        case .nothingToCompact:
            return "Nothing to compact yet — the recent conversation is already as small as it can get"
        case .emptySummary:
            return "The compaction model returned an empty summary"
        case .timedOut:
            return "Context compaction timed out"
        }
    }
}

/// Live progress phases surfaced in the compaction dialog / popover.
enum ContextCompactionPhase: Equatable, Sendable {
    case preparing
    case summarizing
    case applying

    var label: String {
        switch self {
        case .preparing: return L("Analyzing conversation…")
        case .summarizing: return L("Summarizing older messages…")
        case .applying: return L("Applying summary…")
        }
    }

    /// Coarse progress fraction for the dialog's progress bar.
    var progressFraction: Double {
        switch self {
        case .preparing: return 0.15
        case .summarizing: return 0.55
        case .applying: return 0.9
        }
    }
}

/// Session-scoped compaction UI state, published by `ChatSession` and
/// rendered by the Context Budget popover and the compaction dialog.
enum ContextCompactionUIState: Equatable {
    case idle
    /// No model configured — the first-run dialog is asking the user to
    /// pick one before compaction can proceed.
    case needsModelSelection
    case running(ContextCompactionPhase)
    case completed(savedTokens: Int)
    case failed(message: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - Service

/// Stateless orchestration for one compaction run: boundary selection,
/// prompt assembly, model routing (through the same `ModelServiceRouter`
/// the rest of the app uses, so remote models get the Privacy Filter and
/// residency policy for free), and Insights tracing.
@MainActor
final class ContextCompactionService {
    static let shared = ContextCompactionService()

    private let localServices: [ModelService] = [FoundationModelService(), MLXService.shared]

    /// Utilization fraction (of the usable/effective budget) at which the
    /// manual "Compact conversation" button appears in the Context Budget
    /// popover.
    static let manualTriggerThreshold: Double = 0.7

    /// Recent user turns that preferably stay verbatim: the covered span ends
    /// at the second-from-last user turn, so the current exchange plus one
    /// full prior exchange survive in full. When that cut covers nothing
    /// (a conversation of only two exchanges), the boundary falls back to
    /// the last user turn — keeping just the current exchange — provided the
    /// covered span is token-heavy (see `minimumCoveredTokens`).
    static let recentUserTurnsToKeep = 2

    /// A covered span is worth an inference call when it has at least this
    /// many turns…
    static let minimumCoveredTurns = 4

    /// …or, for short-but-huge conversations (e.g. a pasted document plus a
    /// long answer), at least this many estimated tokens. Without this, a
    /// two-exchange chat sitting at 96% of the budget had no compactable
    /// span at all.
    static let minimumCoveredTokens = 4_000

    private static let summaryMaxTokens = 1024
    private static let summaryTemperature: Double = 0.2
    private static let timeoutSeconds: TimeInterval = 180

    private init() {}

    // MARK: Configuration

    static func configuredModelIdentifier() -> String? {
        ChatConfigurationStore.load().compactionModelIdentifier
    }

    /// Persist the user's model choice from the first-run dialog
    /// (load-modify-write, same contract as the Settings screen).
    static func saveConfiguredModel(identifier: String) {
        var cfg = ChatConfigurationStore.load()
        let parts = identifier.split(separator: "/", maxSplits: 1)
        if parts.count == 2 {
            cfg.compactionModelProvider = String(parts[0])
            cfg.compactionModelName = String(parts[1])
        } else {
            cfg.compactionModelProvider = nil
            cfg.compactionModelName = identifier
        }
        ChatConfigurationStore.save(cfg)
    }

    // MARK: Boundary selection

    /// Index into `turns` such that `turns[0..<cut]` is the span a new
    /// summary would cover, or nil when compaction has nothing useful to do.
    ///
    /// The cut preferably lands ON a user turn, so the covered span ends at
    /// a completed exchange and can never split an assistant tool-call from
    /// its tool results. The preferred cut is the second-from-last user turn
    /// (current exchange + one full prior exchange stay verbatim); when that
    /// covers nothing — a conversation of only two exchanges — the cut falls
    /// back to the last user turn, keeping just the current exchange.
    ///
    /// A span is accepted when it has enough turns (`minimumCoveredTurns`)
    /// OR enough estimated tokens (`minimumCoveredTokens`) — the token rule
    /// is what makes short-but-huge conversations (pasted documents, long
    /// generations) compactable. An existing summary only grows: when the
    /// cut wouldn't cover more turns than the current summary already does,
    /// there is nothing to compact.
    ///
    /// Last resort: when no user-turn cut yields a new span (e.g. a
    /// single-exchange chat whose only user message carries a huge pasted
    /// document, or the token weight sits in the current exchange itself),
    /// the whole transcript becomes coverable — `cut == turns.count` — as
    /// long as the last turn is a completed assistant reply and the turns
    /// NOT already covered by the existing summary are themselves
    /// token-heavy. The token gate on the *new* span is what keeps this
    /// from re-summarizing every ordinary exchange at high utilization.
    static func compactionCutIndex(
        turns: [ChatTurn],
        existingSummary: ConversationSummary?
    ) -> Int? {
        let userIndices = turns.enumerated()
            .filter { $0.element.role == .user }
            .map(\.offset)
        guard let lastUserIndex = userIndices.last else { return nil }

        let preferred: Int? =
            userIndices.count >= recentUserTurnsToKeep
            ? userIndices[userIndices.count - recentUserTurnsToKeep] : nil

        // The last-user-turn fallback only exists for the "preferred covers
        // nothing" case. When a non-empty preferred span merely fails the
        // size gate (or an existing summary already covers it), returning
        // the fallback here would silently erode the keep-two-exchanges
        // contract and make every new exchange re-trigger summarization at
        // high utilization.
        let cut: Int
        if let preferred, preferred > 0 {
            cut = preferred
        } else {
            cut = lastUserIndex
        }
        let alreadyCovered = existingSummary?.coveredTurnIds.count ?? 0
        if cut > 0,
            cut > alreadyCovered,
            cut >= minimumCoveredTurns
                || ContextBudgetManager.estimateTokens(for: Array(turns[0 ..< cut]))
                    >= minimumCoveredTokens
        {
            return cut
        }

        // Whole-transcript last resort (see doc comment above).
        guard turns.last?.role == .assistant,
            turns.count > alreadyCovered,
            ContextBudgetManager.estimateTokens(for: Array(turns[alreadyCovered...]))
                >= minimumCoveredTokens
        else { return nil }
        return turns.count
    }

    /// Whether the summary's covered turns still line up with the live
    /// transcript: the covered ids must be exactly the transcript's prefix,
    /// in order. Edits, regenerations, or deletions that touch covered
    /// turns break this and invalidate the summary. Covering the ENTIRE
    /// transcript is legal — the whole-transcript last-resort cut produces
    /// that state, and the next user message simply extends the transcript
    /// past the covered prefix.
    static func summaryIsValid(_ summary: ConversationSummary, for turns: [ChatTurn]) -> Bool {
        guard !summary.coveredTurnIds.isEmpty,
            summary.coveredTurnIds.count <= turns.count
        else { return false }
        for (index, coveredId) in summary.coveredTurnIds.enumerated() {
            guard turns[index].id == coveredId else { return false }
        }
        return true
    }

    // MARK: Run

    struct RunResult {
        let summary: ConversationSummary
    }

    /// Run one compaction pass over `turns`. Throws
    /// `ContextCompactionError.needsModelSelection` when no model is
    /// configured (drives the first-run dialog) and `.nothingToCompact`
    /// when the conversation is too short.
    func summarize(
        turns: [ChatTurn],
        existingSummary: ConversationSummary?,
        sessionId: UUID?,
        onPhase: @MainActor (ContextCompactionPhase) -> Void
    ) async throws -> ConversationSummary {
        onPhase(.preparing)

        guard let modelId = Self.configuredModelIdentifier() else {
            throw ContextCompactionError.needsModelSelection
        }
        guard let cut = Self.compactionCutIndex(turns: turns, existingSummary: existingSummary)
        else {
            throw ContextCompactionError.nothingToCompact
        }

        let covered = Array(turns[0 ..< cut])
        let coveredIds = covered.map(\.id)

        // Resolve the model before building the prompt so an unavailable
        // model fails fast with a clear message.
        let remoteServices: [ModelService] = RemoteProviderManager.shared.connectedServices()
        let route = ModelServiceRouter.resolve(
            requestedModel: modelId,
            services: localServices,
            remoteServices: remoteServices
        )
        guard case .service(let service, _) = route else {
            throw ContextCompactionError.modelUnavailable(modelId)
        }

        // Prompt budget: leave room for the response + instructions inside
        // the compaction model's own window.
        let window = await AgentLoopBudget.resolveContextWindow(modelId: modelId)
        let transcriptCharBudget = max(
            8_000,
            min((window / 2) * TokenEstimator.charsPerToken, 240_000)
        )
        let transcript = Self.renderTranscript(
            covered: covered,
            existingSummary: existingSummary,
            charBudget: transcriptCharBudget
        )

        let messages = [
            ChatMessage(role: "system", content: Self.systemPrompt),
            ChatMessage(role: "user", content: Self.userPrompt(transcript: transcript)),
        ]
        let params = GenerationParameters(
            temperature: Float(Self.summaryTemperature),
            maxTokens: Self.summaryMaxTokens,
            sessionId: sessionId?.uuidString,
            requestSource: .chatUI,
            // The user is actively waiting on compaction (button click or
            // pre-send auto-trigger), so it has the right to load/evict.
            loadIntent: .interactive
        )

        onPhase(.summarizing)
        let startedAt = Date()
        let responseText: String
        do {
            responseText = try await valueWithDeadline(
                seconds: Self.timeoutSeconds,
                operationName: "context compaction"
            ) {
                try await service.generateOneShot(
                    messages: messages,
                    parameters: params,
                    requestedModel: modelId
                )
            }
        } catch is DeadlineExceededError {
            Self.logToInsights(
                model: modelId, messages: messages, response: nil,
                startedAt: startedAt, error: "timed out")
            throw ContextCompactionError.timedOut
        } catch {
            Self.logToInsights(
                model: modelId, messages: messages, response: nil,
                startedAt: startedAt, error: error.localizedDescription)
            throw error
        }

        Self.logToInsights(
            model: modelId, messages: messages, response: responseText,
            startedAt: startedAt, error: nil)

        let summaryText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summaryText.isEmpty else { throw ContextCompactionError.emptySummary }

        onPhase(.applying)
        let coveredTokens = ContextBudgetManager.estimateTokens(for: covered)
        var summary = ConversationSummary(
            summaryText: summaryText,
            coveredTurnIds: coveredIds,
            modelIdentifier: modelId,
            savedTokensEstimate: 0
        )
        let summaryTokens = ContextBudgetManager.estimateTokens(for: summary.contextMessageText)
        summary = ConversationSummary(
            id: summary.id,
            summaryText: summaryText,
            coveredTurnIds: coveredIds,
            createdAt: summary.createdAt,
            modelIdentifier: modelId,
            savedTokensEstimate: max(0, coveredTokens - summaryTokens)
        )
        logger.info(
            "Compacted \(coveredIds.count) turns via \(modelId, privacy: .public): ~\(summary.savedTokensEstimate) tokens reclaimed"
        )
        return summary
    }

    // MARK: Prompt

    private static let systemPrompt = """
        You are a conversation compaction engine. You produce a dense, factual summary of \
        the older portion of a chat between a user and an AI assistant so that the \
        conversation can continue with the summary in place of those messages.

        Requirements:
        - Preserve the user's original task/request and any explicit constraints verbatim where possible.
        - Record key facts, decisions, and answers established so far.
        - Record important tool activity as outcomes (what was searched/read/written and what was found), not step-by-step logs.
        - Record the current state of any in-progress work and what remains to be done.
        - Do NOT invent details. If something was truncated or unclear, say so.
        - Write in compact prose or terse bullet points. No preamble, no closing remarks — output only the summary.
        """

    private static func userPrompt(transcript: String) -> String {
        """
        Summarize the following conversation excerpt (oldest part of an ongoing chat):

        ---
        \(transcript)
        ---

        Output only the summary.
        """
    }

    /// Render the covered turns as a role-labelled transcript. When an
    /// earlier summary exists, its text stands in for the turns it covers
    /// (no point re-feeding already-compacted content). Per-turn tool
    /// results are clipped, and the whole transcript is head/tail clipped
    /// to `charBudget` so a huge history can't blow the compaction model's
    /// own window.
    static func renderTranscript(
        covered: [ChatTurn],
        existingSummary: ConversationSummary?,
        charBudget: Int
    ) -> String {
        let previouslyCovered = existingSummary.map { Set($0.coveredTurnIds) } ?? []
        var lines: [String] = []
        if let existing = existingSummary {
            lines.append("[Summary of even earlier conversation]:\n\(existing.summaryText)")
        }

        for turn in covered {
            if previouslyCovered.contains(turn.id) { continue }
            switch turn.role {
            case .user:
                // The send path prepends attached-document text to the user
                // message (`buildUserMessageText`), so the model's answers
                // are grounded in it — the summary must see it too or a
                // "pasted document + one question" chat summarizes down to
                // just the question. Per-document clip is generous; the
                // whole-transcript charBudget clip below is the real cap.
                var parts: [String] = []
                for doc in turn.attachments.filter(\.isDocument) {
                    guard let text = doc.loadDocumentContent(), !text.isEmpty else { continue }
                    let name = doc.filename ?? "attachment"
                    parts.append(
                        "[User attached document \"\(name)\"]:\n\(clip(text, to: 60_000))"
                    )
                }
                parts.append("[User]: \(clip(turn.content, to: 4_000))")
                lines.append(parts.joined(separator: "\n\n"))
            case .assistant:
                var parts: [String] = []
                if !turn.contentIsBlank {
                    parts.append("[Assistant]: \(clip(turn.content, to: 4_000))")
                }
                for call in turn.toolCalls ?? [] {
                    parts.append(
                        "[Assistant called tool `\(call.function.name)` with: \(clip(call.function.arguments, to: 400))]"
                    )
                }
                if parts.isEmpty { continue }
                lines.append(parts.joined(separator: "\n"))
            case .tool:
                lines.append("[Tool result]: \(clip(turn.content, to: 1_200))")
            case .system:
                continue
            }
        }

        let transcript = lines.joined(separator: "\n\n")
        guard transcript.count > charBudget else { return transcript }
        // Keep the head (original task) and the tail (most recent covered
        // context); drop the middle with an explicit marker.
        let headBudget = charBudget / 4
        let tailBudget = charBudget - headBudget
        let head = String(transcript.prefix(headBudget))
        let tail = String(transcript.suffix(tailBudget))
        return head + "\n\n[… middle of excerpt omitted for length …]\n\n" + tail
    }

    private static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "… [truncated]"
    }

    // MARK: Insights

    /// Record the compaction inference in Insights under a dedicated path
    /// so it is traceable alongside normal chat/API traffic. Token counts
    /// are UI-estimated (same convention as remote chat turns).
    private static func logToInsights(
        model: String,
        messages: [ChatMessage],
        response: String?,
        startedAt: Date,
        error: String?
    ) {
        let requestBody: String? = {
            let payload: [String: Any] = [
                "model": model,
                "purpose": "context_compaction",
                "messages": messages.map { ["role": $0.role, "content": $0.content ?? ""] },
            ]
            guard
                let data = try? JSONSerialization.data(
                    withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            else { return nil }
            return String(decoding: data, as: UTF8.self)
        }()

        let inputTokens = messages.reduce(0) { $0 + TokenEstimator.estimate($1.content) }
        InsightsService.logInference(
            source: .chatUI,
            model: model,
            inputTokens: inputTokens,
            outputTokens: response.map { TokenEstimator.estimate($0) } ?? 0,
            durationMs: Date().timeIntervalSince(startedAt) * 1000,
            temperature: Float(summaryTemperature),
            maxTokens: summaryMaxTokens,
            errorMessage: error,
            requestBody: requestBody,
            responseBody: response,
            path: "/internal/compaction"
        )
    }
}
