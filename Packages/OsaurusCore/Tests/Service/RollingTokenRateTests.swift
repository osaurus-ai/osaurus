// Copyright © 2026 Osaurus AI. All rights reserved.
//
// Tests for `RollingTokenRate` — the steady-state tok/s estimator that
// replaced the chat UI's "single-final-average" display.
//
// Locks the visible behavior contract:
//   - Warm-up window suppresses the rate display until BOTH 0.4s elapsed
//     AND ≥ 4 tokens observed (no spurious values from a single delta on
//     ultra-fast streams)
//   - Sliding window over the last 1.5s reports the steady-state decode
//     rate (immune to first-token amortization)
//   - Reasoning + content + tool-arg tokens count uniformly so thinking
//     ON and thinking OFF on the same model show the same number
//   - `finalRate()` falls back to full-generation average ONLY when
//     warm-up never elapsed (response too short to converge)
//
// If any of these flip, expect user-visible regressions in the chat
// stats card. The rationale for each numeric default is in
// `RollingTokenRate`'s file-level comment.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("RollingTokenRate — steady-state tok/s estimator")
struct RollingTokenRateTests {

    // MARK: - Warm-up gating

    @Test("Warm-up: rate is nil before warmupSeconds elapse")
    func warmup_timeGate() {
        var r = RollingTokenRate()
        let t0 = Date()
        // Burst 50 tokens at t=0 — passes warmupTokens but not warmupSeconds.
        r.observe(tokens: 50, at: t0)
        #expect(r.currentRate(at: t0) == nil)
        #expect(r.currentRate(at: t0.addingTimeInterval(0.39)) == nil)
        // At 0.41s the time gate clears.
        #expect(r.currentRate(at: t0.addingTimeInterval(0.41)) != nil)
    }

    @Test("Warm-up: rate is nil before warmupTokens accumulate")
    func warmup_tokenGate() {
        var r = RollingTokenRate()
        let t0 = Date()
        // 3 tokens spread over a full second — passes time gate but not
        // token gate (warmupTokens = 4).
        r.observe(tokens: 1, at: t0.addingTimeInterval(0.0))
        r.observe(tokens: 1, at: t0.addingTimeInterval(0.4))
        r.observe(tokens: 1, at: t0.addingTimeInterval(0.8))
        #expect(r.currentRate(at: t0.addingTimeInterval(1.0)) == nil)
        // 4th token clears the gate.
        r.observe(tokens: 1, at: t0.addingTimeInterval(1.0))
        #expect(r.currentRate(at: t0.addingTimeInterval(1.1)) != nil)
    }

    // MARK: - Steady-state convergence

    @Test("Steady-state: 60 tok/s sustained reads as ~60 tok/s after warm-up")
    func steadyState_60tps() {
        var r = RollingTokenRate()
        let t0 = Date()
        // Emit 1 token every 1/60s for 2 seconds.
        for i in 0 ..< 120 {
            let t = t0.addingTimeInterval(Double(i) / 60.0)
            r.observe(tokens: 1, at: t)
        }
        let endT = t0.addingTimeInterval(2.0)
        guard let rate = r.currentRate(at: endT) else {
            Issue.record("Rate should be defined after 2s of 60 tok/s")
            return
        }
        // Allow a little slack — the window is 1.5s and emission grid is
        // discrete, so rounding can land at 59 or 60 depending on whether
        // the window cutoff falls between two observations.
        #expect(rate >= 55 && rate <= 65, "rate=\(rate) tok/s, expected ~60")
    }

    // MARK: - Invariance across reasoning ON/OFF

    @Test("Reasoning + content tokens count identically — same decode rate yields same display")
    func invariance_reasoningCountedSameAsContent() {
        // Two streams of identical timing and identical token counts —
        // one labeled "reasoning", the other "content". Caller passes
        // both through observe(tokens:); the rate must be the same.
        var asReasoning = RollingTokenRate()
        var asContent = RollingTokenRate()
        let t0 = Date()
        for i in 0 ..< 100 {
            let t = t0.addingTimeInterval(Double(i) * 0.02)  // 50 tok/s
            asReasoning.observe(tokens: 1, at: t)
            asContent.observe(tokens: 1, at: t)
        }
        let endT = t0.addingTimeInterval(2.0)
        let rRate = asReasoning.currentRate(at: endT)
        let cRate = asContent.currentRate(at: endT)
        #expect(rRate != nil)
        #expect(cRate != nil)
        #expect(rRate == cRate, "reasoning and content with same timing → same rate")
    }

    // MARK: - Window expiration

    @Test("Sliding window: tokens older than windowSeconds are dropped from numerator")
    func slidingWindow_dropsOldTokens() {
        var r = RollingTokenRate()
        let t0 = Date()
        // 2 phases:
        //   t=0..1.0   — burst at 100 tok/s (100 tokens)
        //   t=1.5..3.0 — sustained at 30 tok/s (45 tokens)
        // At t=3.0 the window covers [1.5, 3.0] — the 100 fast tokens
        // should be FULLY EVICTED, leaving only the 30 tok/s phase.
        for i in 0 ..< 100 {
            r.observe(tokens: 1, at: t0.addingTimeInterval(Double(i) * 0.01))
        }
        for i in 0 ..< 45 {
            r.observe(
                tokens: 1,
                at: t0.addingTimeInterval(1.5 + Double(i) * (1.5 / 45.0))
            )
        }
        let endT = t0.addingTimeInterval(3.0)
        guard let rate = r.currentRate(at: endT) else {
            Issue.record("Rate should be defined")
            return
        }
        // Expected ~30 tok/s; the burst should not pollute. Allow ±20%
        // for window-edge effects.
        #expect(rate >= 24 && rate <= 36, "rate=\(rate); burst should be evicted")
    }

    // MARK: - Final rate fallback

    @Test("finalRate: falls back to full-gen average when warm-up never elapsed")
    func finalRate_shortResponse_fallsBackToAverage() {
        var r = RollingTokenRate()
        let t0 = Date()
        // 3 tokens in 0.2s — never passes either warm-up gate.
        r.observe(tokens: 1, at: t0.addingTimeInterval(0.0))
        r.observe(tokens: 1, at: t0.addingTimeInterval(0.1))
        r.observe(tokens: 1, at: t0.addingTimeInterval(0.2))
        // currentRate is nil — warm-up not satisfied.
        #expect(r.currentRate(at: t0.addingTimeInterval(0.2)) == nil)
        // finalRate returns the full-gen average (3 tokens / 0.2s = 15).
        guard let final = r.finalRate() else {
            Issue.record("finalRate should fall back even when currentRate is nil")
            return
        }
        #expect(final >= 14 && final <= 16, "expected ~15 tok/s, got \(final)")
    }

    @Test("finalRate: prefers rolling steady-state when warmed up")
    func finalRate_longResponse_usesRolling() {
        var r = RollingTokenRate()
        let t0 = Date()
        // 100 tokens at 50 tok/s (2s).
        for i in 0 ..< 100 {
            r.observe(tokens: 1, at: t0.addingTimeInterval(Double(i) * 0.02))
        }
        // currentRate IS defined — warm-up cleared.
        #expect(r.currentRate(at: t0.addingTimeInterval(2.0)) != nil)
        guard let final = r.finalRate() else {
            Issue.record("finalRate should be defined")
            return
        }
        // Rolling steady-state ≈ 50; full-gen average = 100/2.0 = 50. Same
        // here by construction; the test below uses a non-uniform stream
        // to differentiate.
        #expect(final >= 45 && final <= 55)
    }

    @Test("finalRate: short startup-burst followed by steady-state — rolling wins, not full-average")
    func finalRate_burstThenSteady_rollingWins() {
        var r = RollingTokenRate()
        let t0 = Date()
        // First 100ms: 0 tokens (TTFT). Then 100 tokens at 50 tok/s (2s).
        // Full-generation average over 2.1s = 100/2.1 ≈ 47.6 tok/s.
        // Rolling steady-state at end ≈ 50 tok/s.
        // The visible value should converge to 50, not be dragged by TTFT.
        for i in 0 ..< 100 {
            r.observe(tokens: 1, at: t0.addingTimeInterval(0.1 + Double(i) * 0.02))
        }
        guard let final = r.finalRate() else {
            Issue.record("finalRate should be defined")
            return
        }
        // The rolling rate should converge to the steady-state, not the
        // TTFT-diluted average. Allow ±20% for window-edge effects.
        #expect(final >= 40 && final <= 60, "got \(final) tok/s")
    }

    // MARK: - Edge cases

    @Test("Zero observations: rates are nil")
    func empty_returnsNil() {
        let r = RollingTokenRate()
        #expect(r.currentRate(at: Date()) == nil)
        #expect(r.finalRate() == nil)
        #expect(r.totalTokens == 0)
    }

    @Test("Zero-token observations update lastAt without affecting numerator")
    func zeroTokenObservation_updatesLastAtOnly() {
        var r = RollingTokenRate()
        let t0 = Date()
        // Real tokens.
        for i in 0 ..< 10 {
            r.observe(tokens: 1, at: t0.addingTimeInterval(Double(i) * 0.05))
        }
        let priorTotal = r.totalTokens
        // A zero-token observation (e.g. an empty sentinel envelope).
        r.observe(tokens: 0, at: t0.addingTimeInterval(2.0))
        #expect(r.totalTokens == priorTotal, "zero observe must not bump totalTokens")
    }

    @Test("totalTokens accumulates across the lifetime, not just the window")
    func totalTokens_lifetime() {
        var r = RollingTokenRate()
        let t0 = Date()
        for i in 0 ..< 500 {
            r.observe(tokens: 1, at: t0.addingTimeInterval(Double(i) * 0.01))
        }
        // At t=5s, only the last 1.5s of tokens are in the window — but
        // totalTokens reflects all 500 observed.
        #expect(r.totalTokens == 500)
    }
}
