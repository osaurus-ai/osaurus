//
//  EvalMTPControl.swift
//  OsaurusEvals
//
//  Explicit, fail-closed native-MTP control for eval runs.
//
//  Why this exists: the eval CLI isolates its storage root before any model
//  loads, so the user's `~/.osaurus/config/server-runtime.json` — including
//  `mtp.mode` — is never read by an eval process. Every run silently resolved
//  MTP as Auto, which made "MTP off" control arms unverifiable (see
//  osaurus#2526). This control pins the requested mode through
//  `ServerRuntimeSettingsStore.overrideSnapshotInMemory` — the SAME snapshot
//  production's `resolveNativeMTPLaunchPlan` (load) and
//  `requestDraftStrategy` (every request) read — so the eval process resolves
//  MTP exactly like the app would with those settings, with nothing persisted
//  to disk.
//
//  Proof contract (fail-closed): a requested control is a claim the report
//  must prove with INDEPENDENT resolution telemetry, because absent
//  generated-token stats are ambiguous by definition ("not requested" and
//  "requested but gate-excluded" both leave `nativeMTPStats == nil`). Three
//  evidence layers, each recorded in the report:
//    1. requested mode/depth (this control),
//    2. resolution — the load-time MTP launch status and the per-request
//       resolved draft strategy from `ModelRuntime.mtpResolution(forModel:)`,
//    3. generated-token stats per step (configured depth, counters).
//  `off` must show a non-MTP resolution AND no token stats; `dN` must show a
//  native_mtp:dN resolution AND configured depth N on every token-producing
//  step; `auto` records what actually resolved (no enforcement). A passing
//  dN row without decode evidence is UNVERIFIED (errored), never a silent
//  pass. Configured depth and adaptive active depth are distinct: the
//  runtime intentionally adapts `activeDepth` during generation, which never
//  fails a row — only the CONFIGURED depth is enforced.
//

import Foundation
import OsaurusCore

/// Parsed value of the `--mtp` eval flag.
public enum EvalMTPControl: Equatable, Sendable {
    /// Native MTP must not run at all.
    case off
    /// Production default resolution (tuning-stamp gated).
    case auto
    /// Force-on at an exact configured draft depth (1...3), bypassing the
    /// measured tuning gate but still requiring MTP tensor evidence.
    case forcedDepth(Int)

    /// Accepts `off`, `auto`, `d1`, `d2`, `d3`.
    public static func parse(_ raw: String) -> EvalMTPControl? {
        switch raw.lowercased() {
        case "off": return .off
        case "auto": return .auto
        case "d1": return .forcedDepth(1)
        case "d2": return .forcedDepth(2)
        case "d3": return .forcedDepth(3)
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .off: return "off"
        case .auto: return "auto"
        case .forcedDepth(let d): return "d\(d)"
        }
    }
}

/// The runtime resolution evidence a verdict is judged against — a
/// harness-side mirror of `ModelRuntime.MTPResolutionSnapshot` so the
/// verdict logic stays a pure, testable function.
public struct EvalMTPResolution: Equatable, Sendable {
    /// Load-time MTP launch status line (nil = load recorded none).
    public let loadStatus: String?
    /// Load-time reason (why MTP engaged, was blocked, or was skipped).
    public let loadReason: String?
    /// Per-request resolved strategy under current settings: "none" for
    /// plain AR, "native_mtp:dN·…" when native MTP is configured.
    public let requestStrategy: String
    /// Configured depth of `requestStrategy` when native MTP, else nil.
    public let requestConfiguredDepth: Int?

    public init(
        loadStatus: String?, loadReason: String?,
        requestStrategy: String, requestConfiguredDepth: Int?
    ) {
        self.loadStatus = loadStatus
        self.loadReason = loadReason
        self.requestStrategy = requestStrategy
        self.requestConfiguredDepth = requestConfiguredDepth
    }

    public var isNativeMTP: Bool { requestConfiguredDepth != nil }
}

/// Outcome of judging one case against the requested control.
public enum EvalMTPVerdict: Equatable, Sendable {
    /// The evidence proves the request was honored.
    case honored
    /// The evidence CONTRADICTS the request — explicit errored row.
    case violation(String)
    /// The evidence is insufficient to prove the request — an otherwise-
    /// passing row becomes errored/unverified rather than silently passing.
    case unverified(String)
}

/// Process-wide record of the requested control so the agent-loop runner can
/// validate every case against it. Set once during bootstrap, before any
/// case runs; read-only afterwards.
public enum EvalMTPControlState {
    nonisolated(unsafe) public private(set) static var requested: EvalMTPControl?

    /// Pin the requested control into the process-local runtime settings
    /// snapshot. Must run AFTER eval storage isolation (so the pin is not
    /// clobbered by a later cold `snapshot()`) and BEFORE the first model
    /// load (so `LoadConfiguration.nativeMTP` and the per-request
    /// `requestDraftStrategy` both see it).
    public static func apply(_ control: EvalMTPControl) {
        var settings = ServerRuntimeSettingsStore.snapshot()
        switch control {
        case .off:
            settings.mtp.mode = .off
            settings.mtp.explicitDepth = nil
        case .auto:
            settings.mtp.mode = .auto
            settings.mtp.explicitDepth = nil
        case .forcedDepth(let depth):
            settings.mtp.mode = .forceOn
            settings.mtp.explicitDepth = depth
        }
        ServerRuntimeSettingsStore.overrideSnapshotInMemory(settings)
        requested = control
        FileHandle.standardError.write(
            Data(
                "[evals] MTP control → requested=\(control.label) pinned mode=\(settings.mtp.mode.rawValue) explicitDepth=\(settings.mtp.explicitDepth.map(String.init) ?? "nil") (process-local)\n"
                    .utf8))
    }

    /// Pure fail-closed judgment of one case.
    ///
    /// - Parameters:
    ///   - requested: the `--mtp` control the run executes under.
    ///   - resolution: independent runtime resolution evidence; nil means
    ///     it could not be captured (no matching resident model — e.g. a
    ///     remote provider), which can prove nothing.
    ///   - tokenStepConfiguredDepths: for every step that has TOKEN
    ///     evidence (`completionTokens > 0`), the configured native-MTP
    ///     depth from that step's stats, nil when the step's tokens were
    ///     produced by a non-MTP path.
    public static func verdict(
        requested: EvalMTPControl,
        resolution: EvalMTPResolution?,
        tokenStepConfiguredDepths: [Int?]
    ) -> EvalMTPVerdict {
        let mtpSteps = tokenStepConfiguredDepths.compactMap { $0 }
        let hasTokenEvidence = !tokenStepConfiguredDepths.isEmpty

        switch requested {
        case .off:
            // Stats-level contradiction outranks everything: MTP produced
            // tokens despite off.
            if !mtpSteps.isEmpty {
                return .violation(
                    "MTP control violated: requested off but native MTP produced tokens (configured depths \(Set(mtpSteps).sorted()))"
                )
            }
            guard let resolution else {
                return .unverified(
                    "requested off but the runtime resolution could not be captured — absent MTP stats alone cannot distinguish off from gate-excluded"
                )
            }
            if resolution.isNativeMTP {
                return .violation(
                    "MTP control violated: requested off but the runtime resolved requestStrategy=\(resolution.requestStrategy)"
                )
            }
            return .honored

        case .auto:
            // Auto enforces nothing, but the report must still SAY what
            // resolved — a run that can't capture resolution proves nothing.
            guard resolution != nil else {
                return .unverified(
                    "requested auto but the runtime resolution could not be captured — the report cannot say what auto resolved to"
                )
            }
            return .honored

        case .forcedDepth(let depth):
            guard let resolution else {
                return .unverified(
                    "requested d\(depth) but the runtime resolution could not be captured"
                )
            }
            guard resolution.requestConfiguredDepth == depth else {
                let reason = resolution.loadReason.map { " (load: \($0))" } ?? ""
                return .violation(
                    "MTP control not honored: requested d\(depth) but the runtime resolved requestStrategy=\(resolution.requestStrategy)\(reason) — unsupported/blocked forced depth is an explicit error row, not a silent Auto/plain fallback"
                )
            }
            guard hasTokenEvidence else {
                return .unverified(
                    "requested d\(depth) and the runtime resolved native_mtp:d\(depth), but the case produced no token-level decode evidence — configured-depth execution is unproven"
                )
            }
            let nonMTP = tokenStepConfiguredDepths.filter { $0 == nil }.count
            if nonMTP > 0 {
                return .violation(
                    "MTP control violated: requested d\(depth) but \(nonMTP) token-producing step(s) ran without native MTP (request-level gate exclusion)"
                )
            }
            let wrong = Set(mtpSteps.filter { $0 != depth })
            if !wrong.isEmpty {
                // Configured depth only — adaptive ACTIVE-depth changes
                // during generation never reach this check.
                return .violation(
                    "MTP control violated: requested configured depth d\(depth) but step stats report configured depth \(wrong.sorted()) (engine depth cap or policy override)"
                )
            }
            return .honored
        }
    }
}
