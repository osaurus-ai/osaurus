//
//  GenerationOutputRelay.swift
//  osaurus
//
//  "The last letters hang": after the final token, vmlx runs its post-generation
//  cache store (measured 9.5–15 s on a 96 GB bundle, 2026-09-04) and only then
//  closes the stream. MLXBatchAdapter deliberately withholds the terminal `.info`
//  until that drain so an immediate follow-up request cannot enter ModelRuntime
//  before this one's allocator window closes. That ordering stays. What the UI
//  needs is a separate, earlier fact — "the model's OUTPUT is complete" — so the
//  streaming cursor can stop at the last letter and the turn can stamp its
//  completion, while the send gate keeps waiting for the real end of the run.
//
//  The adapter announces output completion here the moment `.info` arrives;
//  the chat view subscribes for the duration of its run.
//

import Combine
import Foundation

/// Not actor-isolated: the announcer runs on the adapter's producer task; the
/// published value is only ever written on the main queue, and the chat view
/// already receives on the main run loop.
final class GenerationOutputRelay: ObservableObject, @unchecked Sendable {
    static let shared = GenerationOutputRelay()

    struct Completion: Equatable {
        let modelName: String
        let at: Date
        /// Decode tokens vmlx counted for the run, when the info carried them.
        let generationTokens: Int?
        /// `GenerationParameters.sessionId` of the request that produced this
        /// output — the chat's `session_id`. Nil for requests without one.
        let sessionId: String?
        /// User-visible trigger attribution of the producing request.
        let activitySource: RequestSource
        /// True for internal utility generations (chat title, follow-up
        /// suggestions, memory distillation, transcript cleanup).
        let auxiliary: Bool

        /// Whether this completion belongs to the chat step that started at
        /// `startedAt` for session `sessionId`.
        ///
        /// The relay is process-wide: every local generation announces here,
        /// including the previous chat's title/follow-up/memory jobs (which
        /// queue behind the same solo lease and so finish right AFTER a new
        /// send starts), other tabs, subagents, plugins and API clients. A
        /// timestamp alone let any of those mark a foreign turn's output
        /// complete before its own model had emitted a token — the turn then
        /// rendered as finished (no typing indicator, no "Loading Model...",
        /// no cursor) for its whole run.
        func matches(sessionId expected: String?, startedAt: Date) -> Bool {
            guard at >= startedAt else { return false }
            guard !auxiliary, activitySource != .agent else { return false }
            guard let expected, let sessionId else { return false }
            return sessionId == expected
        }
    }

    @Published private(set) var lastCompletion: Completion?

    func announce(
        modelName: String,
        generationTokens: Int?,
        sessionId: String?,
        activitySource: RequestSource,
        auxiliary: Bool
    ) {
        let completion = Completion(
            modelName: modelName,
            at: Date(),
            generationTokens: generationTokens,
            sessionId: sessionId,
            activitySource: activitySource,
            auxiliary: auxiliary
        )
        DispatchQueue.main.async { self.lastCompletion = completion }
    }
}
