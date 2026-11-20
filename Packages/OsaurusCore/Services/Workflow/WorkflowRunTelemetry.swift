//
//  WorkflowRunTelemetry.swift
//  osaurus
//
//  Derives the closed `workflow_run_finished` tokens from a finished run:
//  what kind of run it was, and, for a failed one, where and why it failed.
//

import Darwin
import Foundation

enum WorkflowRunTelemetry {
    /// Run-level failure kinds raised before any step ran.
    static let preflightKinds: Set<String> = [
        "not_a_workflow", "input_mismatch", "invalid_definition", "graph_cycle", "pin_error",
    ]

    static func runKind(_ run: WorkflowRun) -> String {
        if run.isTest { return "test" }
        if run.wrapperAgentID != nil { return "wrapper" }
        if run.ephemeral { return "ephemeral" }
        return "installed"
    }

    /// Where a failure happened: `preflight` (the run never reached a
    /// step), `sandbox`, `output` (every step finished but the assembled
    /// output did not match), or `step`.
    static func stage(kind: String, nodeID: String?) -> String {
        if preflightKinds.contains(kind) { return "preflight" }
        guard nodeID == nil else { return "step" }
        switch kind {
        case "sandbox_unavailable": return "sandbox"
        case "output_mismatch": return "output"
        default: return "run"
        }
    }

    /// The failure fields for a failed run, nil otherwise. `stepKinds` maps
    /// node ids to `WorkflowNode.kindName`; `route` names the model source
    /// and provider type for a step's model id.
    static func failure(
        _ run: WorkflowRun, stepKinds: [String: String],
        route: (String) -> (source: String, provider: String)
    ) -> FeatureTelemetry.WorkflowRunFailure? {
        guard run.status == .failed else { return nil }
        let failedNode = run.error?.nodeID.flatMap(run.node) ?? run.nodes.first { $0.status == .failed }
        let nodeID = run.error?.nodeID ?? failedNode?.nodeID
        let classified = run.primaryFailure
        let kind = classified?.kind ?? "unclassified"
        let modelRoute = failedNode?.model.map(route)
        return FeatureTelemetry.WorkflowRunFailure(
            stage: stage(kind: kind, nodeID: nodeID),
            kind: kind,
            errorType: classified.map { $0.errorType.isEmpty ? "unknown" : $0.errorType } ?? "unknown",
            fixIn: classified?.fixIn.rawValue ?? "unknown",
            stepKind: nodeID.flatMap { stepKinds[$0] },
            stepsDone: run.nodes.filter { $0.status == .done }.count,
            modelSource: modelRoute?.source,
            providerType: modelRoute?.provider)
    }

    /// The `message_sent` provider tokens for a slot model id: Foundation,
    /// a configured remote provider by its picker prefix, else local MLX.
    @MainActor
    static func liveRoute(_ model: String) -> (source: String, provider: String) {
        if model.caseInsensitiveCompare("foundation") == .orderedSame || model.lowercased() == "default" {
            return ("foundation", "foundation")
        }
        let lowered = model.lowercased()
        if let provider = RemoteProviderManager.shared.configuration.providers.first(where: {
            lowered.hasPrefix(RemoteProviderManager.pickerPrefix(for: $0.name) + "/")
        }) {
            return ("remote", provider.providerType.rawValue)
        }
        return ("local", "mlx")
    }
}

/// When this process started, from the kernel's process table, so runs
/// started early in a launch can be told apart from later ones.
enum ProcessLaunch {
    static let date: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()
}
