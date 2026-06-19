//
//  AxResolvableSweep.swift
//  OsaurusCore — Computer Use
//
//  The "ax-resolvable sweep" the plan calls for running BEFORE any escalation
//  threshold is set. It measures, over a set of probe targets, what fraction
//  the accessibility tree can resolve on its own — the signal that decides
//  whether escalating to som/vision is worth its cost.
//
//  It is pure perception: capture an `ax` snapshot, build the `AgentView`, run
//  the `TargetResolver`, tally outcomes. No model, no loop, no gate — so it
//  runs deterministically against `MockMacDriver` in CI and can also be
//  pointed at live app pids (opt-in, needs Accessibility) for a real sweep.
//

import Foundation

/// A set of target probes to attempt against one app.
public struct AxProbe: Sendable {
    public let pid: Int32
    /// The targets to attempt — typically `describe` phrases a model would use.
    public let targets: [AgentTarget]

    public init(pid: Int32, targets: [AgentTarget]) {
        self.pid = pid
        self.targets = targets
    }
}

/// Tally of a sweep. `resolvableRate` is the headline the thresholds key off.
public struct AxSweepResult: Sendable, Equatable {
    public let total: Int
    public let resolved: Int
    public let reobserve: Int
    public let deadEnd: Int

    public init(total: Int, resolved: Int, reobserve: Int, deadEnd: Int) {
        self.total = total
        self.resolved = resolved
        self.reobserve = reobserve
        self.deadEnd = deadEnd
    }

    /// Fraction of probes the AX tree resolved outright. 0 when there were no
    /// probes (avoids a divide-by-zero in threshold math).
    public var resolvableRate: Double {
        total == 0 ? 0 : Double(resolved) / Double(total)
    }
}

public enum AxResolvableSweep {

    /// Run the sweep. One `ax` capture per probe app, then resolve each target
    /// against that view.
    public static func run(driver: MacDriver, probes: [AxProbe]) async -> AxSweepResult {
        var resolved = 0
        var reobserve = 0
        var deadEnd = 0
        var total = 0

        for probe in probes {
            let snapshot = await driver.capture(pid: probe.pid, tier: .ax)
            let view = AgentView.build(from: snapshot, previous: nil)
            for target in probe.targets {
                total += 1
                switch TargetResolver.resolve(target, view: view, snapshot: snapshot) {
                case .resolved: resolved += 1
                case .reobserve: reobserve += 1
                case .deadEnd: deadEnd += 1
                }
            }
        }

        return AxSweepResult(
            total: total,
            resolved: resolved,
            reobserve: reobserve,
            deadEnd: deadEnd
        )
    }
}
