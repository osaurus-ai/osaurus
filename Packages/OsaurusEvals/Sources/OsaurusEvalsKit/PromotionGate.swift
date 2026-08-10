//
//  PromotionGate.swift
//  OsaurusEvalsKit
//
//  The STRICT promotability decision for the context-optimization
//  harness — deliberately harsher than `EvalDiff` (the review tool):
//  a candidate profile may only be promoted to production composition
//  when the evidence shows NO quality loss at all. The plan's rules,
//  verbatim:
//
//    - no baseline pass→fail transitions (no flake amnesty here — a
//      flip on a flaky row blocks promotion and demands more trials);
//    - no new failures, errors, or SKIPS (a profile that silently
//      shrinks the scored surface must never look like a win);
//    - no LOWER per-case pass rate on repeat-trial (flaky) rows;
//    - the judge-calibration lane, when present, must fully pass;
//    - the case catalog must be unchanged between the two reports
//      (same ids — a candidate can't drop hard cases);
//    - optional hard context budget: the candidate's mean first-step
//      input estimate must fit the configured ceiling.
//
//  Never weaken these to make a profile pass. The output separates
//  blocking findings from advisories so a reviewer sees WHY.
//

import Foundation

public struct PromotionGateResult: Sendable, Codable {
    public let promotable: Bool
    /// Rule violations that block promotion, human-readable.
    public let blocking: [String]
    /// Non-blocking observations worth a reviewer's glance.
    public let advisories: [String]

    public init(blocking: [String], advisories: [String]) {
        self.promotable = blocking.isEmpty
        self.blocking = blocking
        self.advisories = advisories
    }
}

public enum PromotionGate {

    /// Evaluate candidate vs baseline under the strict rules above.
    /// `maxFirstStepContextTokens` adds the hard context budget (nil →
    /// no budget rule).
    public static func evaluate(
        baseline: EvalReport,
        candidate: EvalReport,
        maxFirstStepContextTokens: Int? = nil
    ) -> PromotionGateResult {
        var blocking: [String] = []
        var advisories: [String] = []

        let baselineById = Dictionary(
            baseline.cases.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let candidateById = Dictionary(
            candidate.cases.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Rule: unchanged catalog. Ids must match exactly in both
        // directions — dropped hard cases and injected easy ones both
        // invalidate the comparison.
        let missing = Set(baselineById.keys).subtracting(candidateById.keys).sorted()
        let added = Set(candidateById.keys).subtracting(baselineById.keys).sorted()
        if !missing.isEmpty {
            blocking.append(
                "catalog changed: candidate is missing \(missing.count) baseline case(s): "
                    + missing.prefix(5).joined(separator: ", ")
                    + (missing.count > 5 ? ", …" : "")
            )
        }
        if !added.isEmpty {
            blocking.append(
                "catalog changed: candidate adds \(added.count) case(s) the baseline never ran: "
                    + added.prefix(5).joined(separator: ", ")
                    + (added.count > 5 ? ", …" : "")
            )
        }

        for id in Set(baselineById.keys).intersection(candidateById.keys).sorted() {
            guard let b = baselineById[id], let c = candidateById[id] else { continue }

            // Rule: no pass→not-pass transitions. Strict — flake
            // evidence downgrades nothing here (rerun with more trials
            // instead of promoting on a flip).
            if b.outcome == .passed && c.outcome != .passed {
                blocking.append(
                    "\(id): pass → \(c.outcome.rawValue)"
                        + (c.isFlaky ? " (flaky \(c.trialsPassed ?? 0)/\(c.trials ?? 0) — rerun with more trials)" : "")
                )
            }

            // Rule: no new errors/skips (from any prior outcome). A
            // profile that makes a previously-scoreable case skip or
            // error shrank or broke the surface.
            if c.outcome == .errored && b.outcome != .errored {
                blocking.append("\(id): new error (was \(b.outcome.rawValue))")
            }
            if c.outcome == .skipped && b.outcome != .skipped {
                blocking.append("\(id): new skip (was \(b.outcome.rawValue)) — scored surface shrank")
            }

            // Rule: repeat-aware — no lower per-case pass rate when both
            // sides carry trials. Catches "still passes the merge but got
            // flakier", which a plain outcome comparison misses.
            if let bTrials = b.trials, let bPassed = b.trialsPassed, bTrials > 0,
                let cTrials = c.trials, let cPassed = c.trialsPassed, cTrials > 0
            {
                let bRate = Double(bPassed) / Double(bTrials)
                let cRate = Double(cPassed) / Double(cTrials)
                if cRate < bRate {
                    let line =
                        "\(id): per-case pass rate dropped "
                        + "\(bPassed)/\(bTrials) → \(cPassed)/\(cTrials)"
                    // Only additionally blocking when not already flagged
                    // by the outcome transition above.
                    if b.outcome == .passed && c.outcome == .passed {
                        blocking.append(line)
                    } else if !(b.outcome == .passed && c.outcome != .passed) {
                        advisories.append(line)
                    }
                } else if cRate > bRate {
                    advisories.append(
                        "\(id): per-case pass rate improved "
                            + "\(bPassed)/\(bTrials) → \(cPassed)/\(cTrials)"
                    )
                }
            }
        }

        // Rule: the judge-calibration lane, when present in the candidate
        // run, must fully pass — a candidate measured under a judge that
        // fails its own calibration proves nothing.
        let calibrationFailures = candidate.cases.filter {
            $0.domain == "judge_calibration" && ($0.outcome == .failed || $0.outcome == .errored)
        }
        if !calibrationFailures.isEmpty {
            blocking.append(
                "judge calibration failing: "
                    + calibrationFailures.map(\.id).sorted().joined(separator: ", ")
            )
        }

        // Rule: hard context budget on the candidate's mean first-step
        // input estimate (the cold-prefill surface the search drives down).
        if let budget = maxFirstStepContextTokens {
            let firstSteps = candidate.cases.compactMap { $0.context?.firstStepInputTokens }
            if firstSteps.isEmpty {
                advisories.append(
                    "context budget \(budget) configured but no candidate row carried "
                        + "first-step attribution"
                )
            } else {
                let mean = firstSteps.reduce(0, +) / firstSteps.count
                if mean > budget {
                    blocking.append(
                        "context budget exceeded: mean first-step \(mean) tok > budget \(budget)"
                    )
                } else {
                    advisories.append(
                        "context budget ok: mean first-step \(mean) tok ≤ budget \(budget)"
                    )
                }
            }
        }

        // Advisory: comparability of environments (judge, catalog hash).
        if let bJudge = baseline.environment?.judge,
            let cJudge = candidate.environment?.judge,
            bJudge != cJudge
        {
            advisories.append("judge differs: baseline=\(bJudge) candidate=\(cJudge)")
        }

        return PromotionGateResult(blocking: blocking, advisories: advisories)
    }
}
