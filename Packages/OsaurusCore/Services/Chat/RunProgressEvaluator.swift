//
//  RunProgressEvaluator.swift
//  osaurus
//
//  Pure liveness rules for the composer slow/stalled chips. Progress is
//  events, not flags: a hung tool or wedged load must still age to
//  `.stalled`. Stream tokens latch the chip until a sustained burst;
//  discrete events (tool, exec, load) only reset `previous`.
//

import Foundation

enum RunProgressKind: Equatable, Sendable {
    /// Text / reasoning tokens. A single delta does not clear a latched
    /// `.slow` / `.stalled` — that takes a sustained burst.
    case stream
    /// Tool commit/result, live exec output, subagent feed, load/prefill
    /// update, image/video step. Unlatches, then 30/120 thresholds apply.
    case discrete
}

enum RunProgressState: Equatable, Sendable {
    case active
    case slow
    case stalled
}

enum RunProgressEvaluator {
    static let slowThreshold: TimeInterval = 30
    static let stalledThreshold: TimeInterval = 120
    /// MLX container load publishes only start/end (`loadInFlightCount`). The
    /// typing row shows a static "Loading Model…" with no bytes/fraction, so
    /// events cannot tell a 3-minute 27 GB load from a wedged one. Use a
    /// longer ceiling only for that opaque window; prefill and sandbox have
    /// mid-flight updates and keep the 120s stall.
    static let opaqueModelLoadStalledThreshold: TimeInterval = 600
    static let streamBurstWindow: TimeInterval = 10
    static let streamBurstMinimum = 3

    /// Decide the composer-chip state.
    ///
    /// Order:
    /// 1. idle ≥ stall ceiling → `.stalled` (120s, or 600s during opaque
    ///    model load). Loading phase and latch cannot hide a hang past that.
    /// 2. `clearsLatch` resets `previous` to `.active` and continues
    /// 3. loading phase + idle under the stall ceiling → `.active`
    /// 4. stream latch keeps `.slow` / `.stalled` until a burst
    /// 5. else 30/120 thresholds
    static func state(
        idle: TimeInterval,
        previous: RunProgressState,
        isSustainedStreamBurst: Bool,
        clearsLatch: Bool,
        hasVisibleLoadingPhase: Bool,
        isOpaqueModelLoad: Bool = false
    ) -> RunProgressState {
        let stallAfter =
            isOpaqueModelLoad ? opaqueModelLoadStalledThreshold : stalledThreshold
        if idle >= stallAfter {
            return .stalled
        }

        var previous = previous
        if clearsLatch {
            previous = .active
        }

        if hasVisibleLoadingPhase {
            return .active
        }

        if !isSustainedStreamBurst, previous == .slow || previous == .stalled {
            return previous
        }

        if idle >= slowThreshold {
            return .slow
        }
        return .active
    }

    static func isSustainedStreamBurst(
        timestamps: [Date],
        now: Date = Date()
    ) -> Bool {
        let cutoff = now.addingTimeInterval(-streamBurstWindow)
        return timestamps.lazy.filter { $0 >= cutoff }.count >= streamBurstMinimum
    }
}
