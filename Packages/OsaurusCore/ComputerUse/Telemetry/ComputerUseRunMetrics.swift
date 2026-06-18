//
//  ComputerUseRunMetrics.swift
//  OsaurusCore — Computer Use
//
//  Per-run measurement (PR3). The loop accumulates these counters as it goes;
//  the tool emits a single coarse, privacy-clean event at the end (see
//  `FeatureTelemetry.computerUseRun`). The raw struct also feeds the eval
//  harness, which needs full fidelity (per-app / per-tier) the shipped
//  telemetry intentionally never sends.
//

import Foundation

/// Mutable accumulator for one Computer Use run. `Sendable` so it can move
/// between the loop's async steps; mutated single-threadedly within `run`.
public struct ComputerUseRunMetrics: Sendable, Equatable {
    /// Productive perceive→act cycles completed.
    public var steps = 0
    /// Target-resolution attempts and how many resolved against the AX tree —
    /// the ax-resolvable rate the escalation thresholds key off.
    public var targetResolveAttempts = 0
    public var targetResolveSuccesses = 0
    /// Gate confirmations.
    public var confirmsRequested = 0
    public var confirmsApproved = 0
    public var confirmsDeclined = 0
    /// Gate rejections (allowlist / deny disposition).
    public var blocked = 0
    /// Dead-end terminations encountered (resolution gave out).
    public var deadEnds = 0
    /// Actions executed and how many the verify step saw land (view changed).
    public var actsAttempted = 0
    public var verifyChanged = 0
    /// Clicks that failed at the live AX layer (stale/removed element) and were
    /// retried as a coordinate click at the element's last-known center. High on
    /// Electron, whose element refs die between capture and click.
    public var coordinateFallbacks = 0
    /// Highest capture tier reached during the run.
    public var maxTier: CaptureTier = .ax
    /// Total model tokens (prompt + completion) consumed across all model
    /// steps, summed from each response's usage. `0` when the loop is driven by
    /// a scripted provider (no model call).
    public var modelTokens = 0
    /// Whether the cloud-vision route was ever taken (consented + scrubbed).
    public var cloudVisionUsed = false
    /// Effect-class distribution of gated actions.
    public var effectCounts: [EffectClass: Int] = [:]

    public init() {}

    /// AX-resolvable rate, or `nil` when there were no resolution attempts.
    public var axResolvableRate: Double? {
        guard targetResolveAttempts > 0 else { return nil }
        return Double(targetResolveSuccesses) / Double(targetResolveAttempts)
    }

    /// Fraction of executed actions the verify step observed a change for.
    public var verifyPassRate: Double? {
        guard actsAttempted > 0 else { return nil }
        return Double(verifyChanged) / Double(actsAttempted)
    }

    // MARK: - Mutators (keep call sites in the loop terse)

    public mutating func recordResolveAttempt(success: Bool) {
        targetResolveAttempts += 1
        if success { targetResolveSuccesses += 1 }
    }

    public mutating func recordEffect(_ effect: EffectClass) {
        effectCounts[effect, default: 0] += 1
    }

    public mutating func raiseTier(to tier: CaptureTier) {
        if tier.rank > maxTier.rank { maxTier = tier }
    }
}

extension CaptureTier {
    /// Ladder rank for "highest tier reached" comparisons.
    var rank: Int {
        switch self {
        case .ax: return 0
        case .som: return 1
        case .vision: return 2
        }
    }
}

// MARK: - Coarse buckets (privacy-clean telemetry)

extension ComputerUseRunMetrics {
    /// Low-cardinality bucket for a count (`0`, `1-3`, `4-9`, `10+`).
    static func countBucket(_ n: Int) -> String {
        switch n {
        case ..<1: return "0"
        case 1 ... 3: return "1-3"
        case 4 ... 9: return "4-9"
        default: return "10+"
        }
    }

    /// Low-cardinality bucket for a 0…1 rate (`none`, `low`, `med`, `high`),
    /// or `na` when the rate is undefined.
    static func rateBucket(_ rate: Double?) -> String {
        guard let rate else { return "na" }
        switch rate {
        case ..<0.25: return "low"
        case ..<0.75: return "med"
        default: return "high"
        }
    }
}
