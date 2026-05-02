// Copyright © 2026 Osaurus AI. All rights reserved.
//
// `RollingTokenRate`
//
// Replaces the single-final-average tok/s value the chat UI used to show with
// a steady-state rolling rate that:
//
//   - Skips a warm-up window so first-token latency, reasoning-parser stamp
//     resolution, and per-stream prefill exit don't drag the average down on
//     short responses (the "doesn't ramp up" symptom users reported on
//     thinking-OFF prompts that finish in 100-200 tokens).
//   - Slides over the last N seconds of decode so the visible value reflects
//     CURRENT decode speed, not the cumulative average across the whole
//     generation. Long thinking-mode preambles no longer pull the visible
//     number toward steady-state while content-only short answers no longer
//     get pulled toward setup-cost.
//   - Counts reasoning channel, content channel, and tool-call argument
//     stream tokens uniformly. Vmlx's `info.generationTokenCount` already
//     unifies these on the local-MLX path; this helper enforces the same
//     unification on the remote-provider fallback path so the visible tok/s
//     is computed identically across `local-MLX | remote-API | with-tools |
//     thinking-on/off`.
//
// ## Why a rolling rate (not the full average)
//
// `vmlx`'s `GenerateCompletionInfo.tokensPerSecond` is `generationTokenCount
// / generateTime` — the average over the whole decode loop. For short
// responses, the DECODE is dominated by:
//
//   - first attention pass (one-time per session warmup of MLX kernels)
//   - first reasoning-parser sentinel emission
//   - the final EOS detection + stop-sequence check
//
// On a 50-token answer those costs are 30-50% of wall time. On a 5000-token
// thinking response they are <1%. Same hardware, same model — the AVERAGE
// looks 2× different just from response length. Users perceive this as
// inconsistency between thinking-on and thinking-off because the lengths
// differ by 10×.
//
// A rolling-window rate (last 1-2 seconds OR last 32-64 tokens, whichever
// shorter) reports the steady-state decode rate. Both short and long
// responses converge to the same visible number after warm-up.
//
// ## Window choice
//
// Default: `windowSeconds = 1.5`, `warmupSeconds = 0.4`, `warmupTokens = 4`.
// - 1.5s window: long enough to smooth across the per-token jitter of MLX
//   batched decode (each batch step is ~10-30ms of GPU work), short enough
//   that the displayed value still tracks the user perception of "now"
//   speed.
// - 0.4s warm-up: empirically covers the first-token + first-attention
//   amortisation on M-series. Short enough that even a 30-token answer at
//   60 tok/s sees ~24 tokens reported (skipping ~24 of warm-up amortised).
// - 4-token warm-up: ensures the rate doesn't fire from a single delta on
//   ultra-fast streams where 0.4s would skip the whole answer.
//
// Constants are static-let on the type so callers can override per-test or
// per-platform without re-stamping every call site.
//

import Foundation

/// Sliding-window rate estimator over a stream of (timestamp, tokenCount)
/// observations. Thread-safety: `RollingTokenRate` is a value type holding
/// a fixed-capacity ring buffer. Each chat turn owns its own instance so
/// concurrent reads are not a concern; the type itself is `Sendable`.
struct RollingTokenRate: Sendable {

    // MARK: - Tunables (static so tests can override + comment block above
    // documents the rationale for each default).

    /// Wall-clock seconds skipped after the FIRST observation arrives.
    /// Tokens emitted within this window are still counted in the running
    /// total but don't contribute to the rate display until the warm-up
    /// elapses. See file-level comment for empirical rationale.
    static let warmupSeconds: TimeInterval = 0.4

    /// Minimum number of token observations before the rate display is
    /// allowed to fire — prevents a single delta from producing a wildly
    /// extrapolated tok/s on very fast streams where 0.4s would otherwise
    /// skip the entire answer.
    static let warmupTokens: Int = 4

    /// Sliding window length. The rate is `tokens-in-window / window-seconds`.
    /// Tokens older than this are dropped from the running sum.
    static let windowSeconds: TimeInterval = 1.5

    // MARK: - State

    /// First-observation timestamp. `nil` until the first `observe(...)` call.
    /// Used to gate the warm-up window — the rate display is suppressed
    /// until `(now - firstAt) >= warmupSeconds && totalTokens >= warmupTokens`.
    private var firstAt: Date?

    /// Last-observation timestamp. Used by `currentRate(now:)` to floor
    /// the window denominator at the actual span of observed data — without
    /// this, a stream that pauses for 5 seconds would produce a falsely
    /// low rate just from the empty window slot.
    private var lastAt: Date?

    /// Ring buffer of recent observations. Each entry is `(timestamp, count)`
    /// where `count` is the token count delta for THAT observation (not a
    /// running total — easier to drop the oldest without recomputing).
    /// Capacity matches the maximum decode rate we'd ever see on M-series
    /// (~150 tok/s × `windowSeconds` × safety factor).
    private var window: [(at: Date, tokens: Int)] = []

    /// Running total of all tokens observed across the lifetime of this
    /// estimator. Cheaper to maintain than re-summing the window — also
    /// surfaced via `totalTokens` for the final-stamp `tokenCount` field.
    private(set) var totalTokens: Int = 0

    /// `true` once the warm-up gates (time AND token-count) have both
    /// elapsed. Read-only convenience for the caller — `currentRate(now:)`
    /// returns `nil` until this flips.
    var isWarmedUp: Bool {
        guard let firstAt else { return false }
        let elapsed = Date().timeIntervalSince(firstAt)
        return elapsed >= Self.warmupSeconds && totalTokens >= Self.warmupTokens
    }

    // MARK: - Mutation

    /// Record a token observation. Call once per stream delta with
    /// `tokens = estimatedTokenCount(deltaText)` — the caller is responsible
    /// for deciding what counts as a "token" (consistent estimation across
    /// reasoning/content/tool-arg channels is what gives the metric its
    /// invariance across thinking ON/OFF).
    ///
    /// Pass `0` for non-token deltas (sentinel envelopes, empty chunks)
    /// — they update `lastAt` so the window denominator stays current
    /// without contaminating the numerator.
    mutating func observe(tokens: Int, at now: Date = Date()) {
        if firstAt == nil { firstAt = now }
        lastAt = now
        if tokens > 0 {
            totalTokens += tokens
            window.append((at: now, tokens: tokens))
        }
        evictExpired(now: now)
    }

    /// Return the current rolling rate, or `nil` while still in warm-up.
    /// The denominator is floored at `min(windowSeconds, now - firstAt)` so
    /// a paused stream doesn't get penalised for the gap.
    func currentRate(at now: Date = Date()) -> Double? {
        guard let firstAt, let _ = lastAt else { return nil }
        let elapsedFromFirst = now.timeIntervalSince(firstAt)
        guard elapsedFromFirst >= Self.warmupSeconds, totalTokens >= Self.warmupTokens
        else { return nil }
        let windowSum = window.reduce(0) { $0 + $1.tokens }
        // Window span: from oldest in-window observation to now (or
        // `windowSeconds` whichever is shorter — caps for paused streams).
        let oldestAt = window.first?.at ?? now
        let span = min(Self.windowSeconds, now.timeIntervalSince(oldestAt))
        guard span > 0, windowSum > 0 else { return nil }
        return Double(windowSum) / span
    }

    /// Final steady-state rate at the end of stream — same as `currentRate`
    /// at the moment of `lastAt`. Caller stamps this on `ChatTurn` once
    /// the stream finishes. Falls back to `totalTokens / wallTime` ONLY
    /// if the warm-up never elapsed (response was too short to converge).
    func finalRate() -> Double? {
        guard let firstAt, let lastAt else { return nil }
        if let rolling = currentRate(at: lastAt) { return rolling }
        // Fallback: full-generation average. Better than no number at all
        // for ultra-short responses — same as the pre-rolling behavior.
        let wall = lastAt.timeIntervalSince(firstAt)
        guard wall > 0, totalTokens > 0 else { return nil }
        return Double(totalTokens) / wall
    }

    // MARK: - Internal

    /// Drop observations older than `windowSeconds` from `now`. Cheap O(k)
    /// where k is the number of expired entries (usually 1-2 per call on
    /// fast streams; bounded by the buffer's natural retention).
    private mutating func evictExpired(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.windowSeconds)
        while let oldest = window.first, oldest.at < cutoff {
            window.removeFirst()
        }
    }
}
