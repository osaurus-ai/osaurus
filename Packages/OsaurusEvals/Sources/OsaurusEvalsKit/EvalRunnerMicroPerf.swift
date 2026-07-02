//
//  EvalRunnerMicroPerf.swift
//  OsaurusEvalsKit
//
//  Runner for the `micro_perf` domain — the dedicated perf lane. The
//  behaviour suites record tok/s / TTFT as a ride-along over whatever
//  prompt each case needed, so their perf numbers move when fixtures
//  move and can't anchor a trend. This lane pins BOTH sides of the
//  request — fixed prompt (query × promptRepeat), fixed decode length
//  (max_tokens) — and reports median ± stdev over N reps measured after
//  one unmeasured warm-up, all in one warm process: the stable row for
//  `history.jsonl`. Steady-state by design (same prompt, same session);
//  cold-start TTFT remains visible in behaviour rows' first steps.
//
//  Decode speed comes from the runtime's authoritative stats hint via
//  `MicroPerfEvaluator` (OsaurusCore). Hint-less paths (Foundation, most
//  remotes) get a clearly-labelled `~est` chars/4 estimate in the notes,
//  and telemetry stays authoritative-only so the matrix perf rollup
//  never mixes measured and estimated speeds.
//

import Foundation
import OsaurusCore

extension EvalRunner {
    static func runMicroPerfCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id

        guard let exp = testCase.expect.microPerf else {
            return Self.errored(
                testCase,
                label: label,
                modelId: modelId,
                note: "missing `expect.microPerf`"
            )
        }
        guard exp.reps >= 2 else {
            return Self.errored(
                testCase,
                label: label,
                modelId: modelId,
                note: "microPerf.reps must be >= 2 for median/stdev (got \(exp.reps))"
            )
        }
        guard exp.maxTokens >= 1 else {
            return Self.errored(
                testCase,
                label: label,
                modelId: modelId,
                note: "microPerf.maxTokens must be >= 1 (got \(exp.maxTokens))"
            )
        }

        let repeatCount = max(1, exp.promptRepeat ?? 1)
        let prompt = Array(repeating: testCase.query, count: repeatCount)
            .joined(separator: " ")

        let overallStart = Date()
        let transcript = await MicroPerfEvaluator.run(
            prompt: prompt,
            maxTokens: exp.maxTokens,
            reps: exp.reps
        )
        let totalWallMs = Date().timeIntervalSince(overallStart) * 1000

        if let err = transcript.error {
            var notes = ["micro-perf run failed: \(err)"]
            if !transcript.samples.isEmpty {
                notes.append("completed reps before failure: \(transcript.samples.count)")
            }
            return EvalCaseReport(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                query: nil,
                outcome: .errored,
                notes: notes,
                modelId: modelId,
                latencyMs: totalWallMs
            )
        }

        let samples = transcript.samples
        // No case-notes echo here — EvalRunner.annotatedWithCaseNotes already
        // prepends `note:` to every report.
        var notes: [String] = [
            "protocol: 1 warm-up + \(exp.reps) reps · max_tokens \(exp.maxTokens) · "
                + "prompt \(prompt.count) chars (query × \(repeatCount)) · steady-state (one session)"
        ]

        var passed = true
        let wallStats = MicroPerfStats(nonEmpty: samples.map(\.wallMs))

        // Decode speed: authoritative-only median, or a labelled estimate.
        let authoritativeTps = samples.compactMap(\.decodeTokensPerSecond)
        var medianDecodeTps: Double?
        if authoritativeTps.count == samples.count,
            let stats = MicroPerfStats(nonEmpty: authoritativeTps)
        {
            medianDecodeTps = stats.median
            notes.append(
                "decode tok/s: \(stats.formatted(digits: 1)) (authoritative, n=\(stats.count))"
            )
        } else if authoritativeTps.isEmpty {
            let estimates: [Double] = samples.compactMap { sample in
                guard let ttft = sample.ttftMs else { return nil }
                let decodeSeconds = (sample.wallMs - ttft) / 1000
                guard decodeSeconds > 0.05 else { return nil }
                return Double(sample.contentChars) / 4.0 / decodeSeconds
            }
            if let stats = MicroPerfStats(nonEmpty: estimates) {
                notes.append(
                    "decode tok/s: ~\(stats.formatted(digits: 1)) "
                        + "(ESTIMATE chars/4 ÷ decode-wall — no runtime stats hint; n=\(stats.count))"
                )
            } else {
                notes.append(
                    "decode tok/s: unmeasured (no stats hint, output too small to estimate)"
                )
            }
        } else {
            notes.append(
                "WARNING: stats hint on only \(authoritativeTps.count)/\(samples.count) reps — "
                    + "median withheld (mixed measurement)"
            )
        }

        let ttftStats = MicroPerfStats(nonEmpty: samples.compactMap(\.ttftMs))
        if let ttftStats {
            notes.append(
                "TTFT ms: \(ttftStats.formatted(digits: 0)) (steady-state, n=\(ttftStats.count))"
            )
            if let ceiling = exp.maxTtftMs, ttftStats.median > ceiling {
                passed = false
                notes.append(
                    String(
                        format: "FLOOR: median TTFT %.0fms exceeds maxTtftMs %.0fms",
                        ttftStats.median,
                        ceiling
                    )
                )
            }
        }
        let prefillStats = MicroPerfStats(nonEmpty: samples.compactMap(\.prefillTokensPerSecond))
        if let prefillStats {
            notes.append("prefill tok/s: \(prefillStats.formatted(digits: 0)) (warm prefix)")
        }
        if let wallStats {
            notes.append(
                "wall ms/rep: \(wallStats.formatted(digits: 0)) · total \(Int(totalWallMs))ms"
            )
        }

        // Fixed-decode-length audit: a rep that stopped early (EOS before
        // max_tokens) makes tok/s comparisons subtly unfair — call it out.
        let counts = samples.compactMap(\.tokenCount)
        if counts.count == samples.count {
            notes.append("tokens/rep: \(counts.map(String.init).joined(separator: " "))")
            if counts.contains(where: { $0 < exp.maxTokens }) {
                notes.append(
                    "WARNING: some reps stopped before max_tokens \(exp.maxTokens) — "
                        + "prompt does not saturate the decode cap for this model"
                )
            }
        }

        if let floor = exp.minDecodeTokensPerSecond {
            if let median = medianDecodeTps {
                if median < floor {
                    passed = false
                    notes.append(
                        String(
                            format:
                                "FLOOR: median decode %.1f tok/s below minDecodeTokensPerSecond %.1f",
                            median,
                            floor
                        )
                    )
                }
            } else {
                passed = false
                notes.append(
                    "FLOOR: minDecodeTokensPerSecond set but no authoritative decode measurement"
                )
            }
        }

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: nil,  // fixed benchmark prompt, not an interesting query
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: wallStats?.median,
            telemetry: EvalCaseTelemetry(
                decodeTokensPerSecond: medianDecodeTps,
                prefillTokensPerSecond: prefillStats?.median,
                ttftMs: ttftStats?.median,
                completionTokens: counts.count == samples.count ? counts.reduce(0, +) : nil
            )
        )
    }
}

/// Median/stdev over a non-empty sample — tiny, dependency-free, and kept
/// internal to the perf lane (other rollups use means on purpose).
struct MicroPerfStats {
    let median: Double
    let stdev: Double
    let count: Int

    init?(nonEmpty values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        median =
            sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
        let mean = values.reduce(0, +) / Double(values.count)
        let variance =
            values.count > 1
            ? values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1)
            : 0
        stdev = variance.squareRoot()
        count = values.count
    }

    func formatted(digits: Int) -> String {
        String(format: "median %.\(digits)f ± %.\(digits)f", median, stdev)
    }
}
