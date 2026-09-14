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
    /// Confirms that could not be shown at all (no chat surface mounted to
    /// render the card). The run ends as `gaveUp` on the first one.
    public var confirmsUnpresentable = 0
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
    /// Mutating actions whose input was posted (the driver returned success)
    /// but whose verify capture saw no view change. Synthesized input is
    /// fire-and-forget on macOS — SkyLight / per-pid posting carries no
    /// delivery acknowledgement — so this is the count of "we cannot prove it
    /// landed" steps the model was told about honestly instead of as success.
    public var unverifiedActs = 0
    /// Per-route tally of synthesized input the driver reported, so the coarse
    /// telemetry can name the dominant transport (`skyLight` on Chromium,
    /// `perPid` on Cocoa, `hidFallback` when the cursor had to move).
    public var routeCounts: [InputRoute: Int] = [:]
    /// Highest capture tier reached during the run.
    public var maxTier: CaptureTier = .ax
    /// Total model tokens (prompt + completion) consumed across all model
    /// steps, summed from each response's usage. `0` when the loop is driven by
    /// a scripted provider (no model call).
    public var modelTokens = 0
    /// Running sum + count of per-step decode speeds (tok/s) reported by the
    /// model responses, used to derive `meanDecodeTokensPerSecond`. Each CU
    /// step is one forced single-tool-call decode, so a per-step arithmetic
    /// mean is a faithful "how fast did this model drive the loop" signal.
    /// Both stay `0` for the scripted seam (no model call) and for providers
    /// that don't report a rate, so the mean reads as "no measurement".
    public var decodeTpsSum: Double = 0
    public var decodeTpsSamples = 0
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

    /// Mean decode speed (tok/s) across the model steps that reported one, or
    /// `nil` when no step did (scripted run / non-reporting provider). The
    /// eval harness surfaces this as the CU row's `decodeTokensPerSecond`.
    public var meanDecodeTokensPerSecond: Double? {
        guard decodeTpsSamples > 0 else { return nil }
        return decodeTpsSum / Double(decodeTpsSamples)
    }

    // MARK: - Mutators (keep call sites in the loop terse)

    public mutating func recordResolveAttempt(success: Bool) {
        targetResolveAttempts += 1
        if success { targetResolveSuccesses += 1 }
    }

    /// Fold one model step's decode speed into the running mean. A `nil` or
    /// non-positive rate (scripted seam, provider that doesn't report one) is
    /// ignored so it never drags the mean toward zero.
    public mutating func recordDecodeTokensPerSecond(_ tps: Double?) {
        guard let tps, tps > 0 else { return }
        decodeTpsSum += tps
        decodeTpsSamples += 1
    }

    public mutating func recordEffect(_ effect: EffectClass) {
        effectCounts[effect, default: 0] += 1
    }

    public mutating func raiseTier(to tier: CaptureTier) {
        if tier.rank > maxTier.rank { maxTier = tier }
    }

    /// Tally the transport one action's input went through. `nil` (an AX
    /// action such as `AXPress`, or a driver that doesn't report routes) is
    /// not counted — it isn't a synthesized-input route.
    public mutating func recordRoute(_ route: InputRoute?) {
        guard let route else { return }
        routeCounts[route, default: 0] += 1
    }

    /// Low-cardinality token for the run's dominant input transport: the
    /// single route used when only one was, `mixed` when several were, and
    /// `none` when no synthesized input was posted at all.
    public var dominantRouteToken: String {
        let used = routeCounts.filter { $0.value > 0 }
        switch used.count {
        case 0: return "none"
        case 1: return used.keys.first!.telemetryToken
        default: return "mixed"
        }
    }
}

extension InputRoute {
    /// Stable snake_case analytics token, decoupled from the Swift case name.
    var telemetryToken: String {
        switch self {
        case .skyLight: return "sky_light"
        case .perPid: return "per_pid"
        case .hidFallback: return "hid_fallback"
        }
    }
}

// MARK: - Pre-loop refusal stages (privacy-clean telemetry)

/// Which pre-loop gate refused a `computer_use` invocation. Closed vocabulary:
/// the dashboard segments `computer_use_refused` by this token, so adding a
/// case is an analytics contract change. Order follows the entry path.
public enum ComputerUseRefusalStage: String, Sendable, CaseIterable {
    /// `ToolRegistry.runPermissionGate`: Accessibility not granted.
    case permissionAccessibility = "permission_accessibility"
    /// `ComputerUseKind.resolveModel`: Default agent, unknown agent, Tools
    /// off, or the per-agent flag off.
    case agentAuth = "agent_auth"
    /// `SubagentModelResolution`: no model selected / configured override
    /// not available.
    case modelUnavailable = "model_unavailable"
    /// Residency: a different local model is required but Local Orchestrator
    /// Handoff is disabled.
    case handoffDenied = "handoff_denied"
    /// `SubagentSession` recursion guard: called from inside another subagent.
    case recursion = "recursion"
    /// `SubagentAdmission`: waited for the local GPU past the timeout.
    case admissionTimeout = "admission_timeout"
    /// Post-admission RAM-safety verdict: no capacity for a child run.
    case ramSafety = "ram_safety"
    /// Stopped by the user or cancelled before the loop started.
    case cancelled
    /// Any other pre-loop failure (kept so the funnel stays total).
    case other
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
