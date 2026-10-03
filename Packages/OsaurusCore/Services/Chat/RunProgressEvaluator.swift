//
//  RunProgressEvaluator.swift
//  osaurus
//
//  Pure liveness rules for the composer slow/stalled chips. Progress is
//  events, not flags. Stream tokens latch until a burst; discrete events
//  reset `previous` and then follow the 30s / stall-ceiling thresholds.
//

import Foundation

enum RunProgressKind: Equatable, Sendable {
    /// Text / reasoning tokens. One delta does not clear a latched chip.
    case stream
    /// Tool, exec, subagent, load/prefill, or image/video step. Unlatches.
    case discrete
}

enum RunProgressState: Equatable, Sendable {
    case active
    case slow
    case stalled
}

/// Typing-row phase used only to hide the redundant `.slow` chip and to
/// pick the stall ceiling. Never used as "still working ⇒ not stalled."
enum RunProgressLoadingPhase: Equatable, Sendable {
    case none
    case sandbox
    case prefill
    case modelLoad

    var hidesSlowChip: Bool { self != .none }

    var stallThreshold: TimeInterval {
        self == .modelLoad
            ? RunProgressEvaluator.opaqueModelLoadStalledThreshold
            : RunProgressEvaluator.stalledThreshold
    }

    /// Same priority as `NativeTypingIndicatorView`: sandbox, then prefill,
    /// then opaque MLX / warmup load.
    @MainActor
    static func current(agentId: UUID?) -> RunProgressLoadingPhase {
        let progress = InferenceProgressManager.shared
        let sandbox = SandboxManager.State.shared
        let id = agentId ?? Agent.defaultId
        let usesSandbox =
            AgentManager.shared.effectiveAutonomousExec(for: id)?.enabled == true
        if usesSandbox && (sandbox.status == .starting || sandbox.isProvisioning) {
            return .sandbox
        }
        if progress.prefillProgress != nil { return .prefill }
        if progress.isLoadingModel { return .modelLoad }
        let warmup = WarmupProgressHub.shared.phases.values
        if warmup.contains(.loadingModel) { return .modelLoad }
        if warmup.contains(where: { if case .prefilling = $0 { return true }; return false }) {
            return .prefill
        }
        return .none
    }
}

enum RunProgressEvaluator {
    static let slowThreshold: TimeInterval = 30
    static let stalledThreshold: TimeInterval = 120
    /// MLX `loadContainer` publishes only start/end. The typing row is a
    /// static "Loading Model…" — no bytes or fraction — so a 3-minute 27 GB
    /// load cannot be told from a hang. Only that window uses 10 minutes.
    static let opaqueModelLoadStalledThreshold: TimeInterval = 600
    static let streamBurstWindow: TimeInterval = 10
    static let streamBurstMinimum = 3

    static func state(
        idle: TimeInterval,
        previous: RunProgressState,
        isSustainedStreamBurst: Bool,
        clearsLatch: Bool,
        loadingPhase: RunProgressLoadingPhase
    ) -> RunProgressState {
        if idle >= loadingPhase.stallThreshold {
            return .stalled
        }

        var previous = previous
        if clearsLatch {
            previous = .active
        }

        if loadingPhase.hidesSlowChip {
            return .active
        }

        if !isSustainedStreamBurst, previous == .slow || previous == .stalled {
            return previous
        }

        return idle >= slowThreshold ? .slow : .active
    }

    static func recordStreamTimestamp(_ timestamps: inout [Date], at now: Date) {
        timestamps.append(now)
        let cutoff = now.addingTimeInterval(-streamBurstWindow)
        guard let first = timestamps.first, first < cutoff else { return }
        timestamps.removeAll { $0 < cutoff }
    }

    static func isSustainedStreamBurst(
        timestamps: [Date],
        now: Date = Date()
    ) -> Bool {
        let cutoff = now.addingTimeInterval(-streamBurstWindow)
        return timestamps.lazy.filter { $0 >= cutoff }.count >= streamBurstMinimum
    }
}
