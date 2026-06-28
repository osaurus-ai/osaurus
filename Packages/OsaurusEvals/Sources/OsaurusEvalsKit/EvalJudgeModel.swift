//
//  EvalJudgeModel.swift
//  OsaurusEvalsKit
//
//  Resolves the rubric-judge model for the `capability_claims` and
//  `agent_loop` domains.
//
//  Self-judging — a small local model grading its own output — is a known
//  eval-trust hole: the rubric grade is only as good as the judge, and a
//  4B model both produces and scores the answer. The historical default
//  (no `JUDGE_MODEL` ⇒ judge with the run model) silently self-judged.
//
//  This resolver instead, when `JUDGE_MODEL` is unset, prefers a strong
//  remote judge whose API key the maintainer has ALREADY exported (the
//  frontier model they are running the suite against). It falls back to
//  self-judge only when no such key exists, and warns loudly so an
//  unreliable grade is never silent. An explicit `JUDGE_MODEL` always
//  wins (warning only if it equals the run model).
//

import Foundation

public enum EvalJudgeModel {

    /// Strong-judge candidates in priority order: (API-key env var, model
    /// id). Each model id is a `provider/name` that
    /// `EvalRemoteProviderBootstrap` already knows how to connect in-process
    /// from the matching `<PREFIX>_API_KEY`.
    static let strongJudgeCandidates: [(envKey: String, modelId: String)] = [
        ("XAI_API_KEY", "xai/grok-4.3"),
        ("ANTHROPIC_API_KEY", "anthropic/claude-sonnet-4-5"),
        ("OPENAI_API_KEY", "openai/gpt-5.1"),
        // Routing prefix MUST match an `EvalRemoteProviderBootstrap.presets`
        // key so the ephemeral provider connects. Gemini's preset is keyed
        // `google` (the app's Google provider), so the model id is
        // `google/<model>`, NOT `gemini/<model>` — the latter has no preset,
        // so the bootstrap skips it and the judge silently never resolves.
        ("GEMINI_API_KEY", "google/gemini-2.5-pro"),
    ]

    /// Outcome of judge resolution.
    public struct Resolution: Sendable {
        /// The model id to grade with, or nil to self-judge with the run
        /// model (the legacy fallback, used only when no strong judge is
        /// reachable).
        public let modelId: String?
        /// True when grading will use the run model itself.
        public let isSelfJudge: Bool
        /// A human-facing note (warning or info) to surface once, or nil
        /// when an explicit non-self judge needs no commentary.
        public let note: String?
    }

    /// Resolve the judge for a run whose model is `runModelId`. Pure: emits
    /// no output. Use `resolveAndWarnOnce` from the runners so the note is
    /// printed at most once per process.
    public static func resolve(
        runModelId: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Resolution {
        if let explicit = environment["JUDGE_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !explicit.isEmpty
        {
            let selfJudge = (explicit == runModelId)
            return Resolution(
                modelId: explicit,
                isSelfJudge: selfJudge,
                note: selfJudge
                    ? "[evals] WARNING: JUDGE_MODEL '\(explicit)' equals the run model — "
                        + "self-judging; rubric grades are unreliable."
                    : nil
            )
        }

        for candidate in strongJudgeCandidates {
            if let key = environment[candidate.envKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !key.isEmpty
            {
                // Don't "upgrade" to a judge that IS the run model.
                if candidate.modelId == runModelId { continue }
                return Resolution(
                    modelId: candidate.modelId,
                    isSelfJudge: false,
                    note: "[evals] JUDGE_MODEL unset; auto-selected strong judge "
                        + "'\(candidate.modelId)' (from \(candidate.envKey)). "
                        + "Set JUDGE_MODEL to override."
                )
            }
        }

        return Resolution(
            modelId: nil,
            isSelfJudge: true,
            note: "[evals] WARNING: JUDGE_MODEL unset and no strong-judge API key found "
                + "(\(strongJudgeCandidates.map(\.envKey).joined(separator: ", "))). "
                + "Falling back to SELF-JUDGE with the run model"
                + (runModelId.map { " '\($0)'" } ?? "")
                + "; rubric grades are unreliable. Export JUDGE_MODEL=provider/name."
        )
    }

    /// Resolve and print the resolution note to stderr at most once per
    /// process for a given note (avoids spamming every case in a suite).
    /// Returns the model id to pass to the judge (nil ⇒ self-judge).
    public static func resolveAndWarnOnce(
        runModelId: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let resolution = resolve(runModelId: runModelId, environment: environment)
        if let note = resolution.note {
            warnOnce(note)
        }
        return resolution.modelId
    }

    // MARK: - One-shot warning dedup

    private static let warnLock = NSLock()
    nonisolated(unsafe) private static var warnedNotes: Set<String> = []

    private static func warnOnce(_ note: String) {
        warnLock.lock()
        let isNew = warnedNotes.insert(note).inserted
        warnLock.unlock()
        guard isNew else { return }
        FileHandle.standardError.write(Data((note + "\n").utf8))
    }
}
