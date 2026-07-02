//
//  MicroPerfEvaluator.swift
//  OsaurusCore
//
//  Fixed-shape generation micro-benchmark driver for the `micro_perf`
//  eval domain. Runs the SAME single-message prompt through the real
//  ChatEngine streaming path N+1 times (one unmeasured warm-up, N
//  measured reps) with a fixed decode cap, and samples each rep's wall
//  clock, TTFT, and the runtime's authoritative StreamingStatsHint
//  (decode tok/s, prefill tok/s, token count). No tools, no system
//  prompt, temperature 0 — both sides of the request are pinned so the
//  numbers are comparable run-over-run, unlike behaviour rows whose
//  prompt/decode sizes move with fixtures.
//
//  Lives in OsaurusCore (not the evals kit) because the streaming hint
//  decoders are internal runtime surface: this is the one sanctioned
//  place that turns them into a benchmark sample.
//

import Foundation

/// One measured generation of the fixed benchmark request.
public struct MicroPerfSample: Sendable, Codable {
    /// Wall clock for the whole rep (dispatch → stream end), ms.
    public let wallMs: Double
    /// Dispatch → first streamed delta (any channel), ms. nil when the
    /// stream produced nothing.
    public let ttftMs: Double?
    /// Authoritative decode speed from the runtime's end-of-step stats
    /// hint. nil when the path never emitted one (Foundation, most
    /// remotes) — callers may estimate, but must label it.
    public let decodeTokensPerSecond: Double?
    /// First positive prefill (prompt-processing) speed reading, tok/s.
    public let prefillTokensPerSecond: Double?
    /// Authoritative generated-token count from the stats hint.
    public let tokenCount: Int?
    /// Visible content characters streamed (estimation substrate for
    /// hint-less paths: chars/4 ≈ tokens).
    public let contentChars: Int

    public init(
        wallMs: Double,
        ttftMs: Double?,
        decodeTokensPerSecond: Double?,
        prefillTokensPerSecond: Double?,
        tokenCount: Int?,
        contentChars: Int
    ) {
        self.wallMs = wallMs
        self.ttftMs = ttftMs
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.tokenCount = tokenCount
        self.contentChars = contentChars
    }
}

/// Result of a micro-perf run: the measured samples, or the error that
/// stopped it (partial samples are kept for forensics).
public struct MicroPerfTranscript: Sendable, Codable {
    /// Measured reps, in order (the warm-up rep is never included).
    public let samples: [MicroPerfSample]
    /// Non-nil when a rep failed; `samples` holds the reps that finished.
    public let error: String?
    /// Which generation failed: 0 = warm-up, 1…N = measured rep index.
    public let failedRepIndex: Int?

    public init(samples: [MicroPerfSample], error: String? = nil, failedRepIndex: Int? = nil) {
        self.samples = samples
        self.error = error
        self.failedRepIndex = failedRepIndex
    }
}

/// Benchmark driver. MainActor for the same reason as the other eval
/// evaluators: engine construction and config-store reads are
/// main-actor-isolated.
@MainActor
public enum MicroPerfEvaluator {
    /// Run 1 unmeasured warm-up + `reps` measured generations of `prompt`
    /// with a fixed `maxTokens` decode cap. `model` defaults to whatever
    /// the config store routes to (the eval runner's ModelOverride).
    public static func run(
        prompt: String,
        maxTokens: Int,
        reps: Int,
        model: String? = nil
    ) async -> MicroPerfTranscript {
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        let engine = ChatEngine()
        // One session for every rep: the content-addressed KV grouping sees
        // one conversation, so measured reps are steady-state (prefix warm)
        // — the stability this lane exists to provide.
        let sessionId = UUID().uuidString

        func makeRequest() -> ChatCompletionRequest {
            ChatCompletionRequest(
                model: resolvedModel,
                messages: [ChatMessage(role: "user", content: prompt)],
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
        }

        func runRep() async throws -> MicroPerfSample {
            let started = Date()
            var ttftMs: Double?
            var decodeTps: Double?
            var prefillTps: Double?
            var tokenCount: Int?
            var contentChars = 0
            let stream = try await engine.streamChat(request: makeRequest())
            for try await delta in stream {
                if ttftMs == nil {
                    ttftMs = Date().timeIntervalSince(started) * 1000
                }
                if StreamingReasoningHint.decode(delta) != nil { continue }
                if let stats = StreamingStatsHint.decode(delta) {
                    if stats.tokensPerSecond > 0 { decodeTps = stats.tokensPerSecond }
                    if stats.tokenCount > 0 { tokenCount = stats.tokenCount }
                    if prefillTps == nil, let prefill = stats.prefillTokensPerSecond, prefill > 0 {
                        prefillTps = prefill
                    }
                    continue
                }
                if StreamingToolHint.isSentinel(delta) { continue }
                contentChars += delta.count
            }
            return MicroPerfSample(
                wallMs: Date().timeIntervalSince(started) * 1000,
                ttftMs: ttftMs,
                decodeTokensPerSecond: decodeTps,
                prefillTokensPerSecond: prefillTps,
                tokenCount: tokenCount,
                contentChars: contentChars
            )
        }

        do {
            _ = try await runRep()  // warm-up: JIT + prefix store, discarded
        } catch {
            return MicroPerfTranscript(
                samples: [],
                error: "warm-up generation failed: \(error)",
                failedRepIndex: 0
            )
        }

        var samples: [MicroPerfSample] = []
        for index in 1 ... max(1, reps) {
            do {
                samples.append(try await runRep())
            } catch {
                return MicroPerfTranscript(
                    samples: samples,
                    error: "rep \(index)/\(reps) failed: \(error)",
                    failedRepIndex: index
                )
            }
        }
        return MicroPerfTranscript(samples: samples)
    }
}
