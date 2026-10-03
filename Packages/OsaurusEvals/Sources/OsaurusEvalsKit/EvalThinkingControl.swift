//
//  EvalThinkingControl.swift
//  OsaurusEvals
//
//  Process-wide default for the model's reasoning ("thinking") mode on
//  agent-loop and micro-perf cases, set once from the CLI's
//  `--thinking on|off` flag.
//
//  Contract:
//  - A case's own `expect.agentLoop.enableThinking` (or the micro-perf
//    equivalent) always wins; the CLI value only fills in cases that leave
//    it unset.
//  - nil (flag absent) means the bundle's documented default reasoning
//    mode — exactly what a user gets when they load the model in Osaurus.
//  - The requested value is stamped into every report's `RunEnvironment`
//    (`thinkingControl`) so a `no_think` lane is never silently compared
//    with a default-mode lane.
//
//  This is a legitimate per-request reasoning switch the model bundle
//  advertises (e.g. the `enable_thinking` chat-template flag), not prompt or
//  template coercion. It exists because full-lane wall-clock for large
//  reasoning budgets can exceed what a proof run can afford; the default-mode
//  lane must still be reported honestly (as BLOCKED/PARTIAL when it cannot be
//  completed), never replaced by the `off` lane.
//

import Foundation

public enum EvalThinkingControlState {
    nonisolated(unsafe) public private(set) static var requested: Bool?

    /// Parse the CLI value. Accepts `on|off|true|false|1|0` (case-insensitive).
    public static func parse(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on", "true", "1", "yes", "think": return true
        case "off", "false", "0", "no", "no_think", "nothink": return false
        default: return nil
        }
    }

    /// Record the process-wide default. Call once during bootstrap.
    public static func apply(_ enabled: Bool) {
        requested = enabled
    }

    /// Effective per-case value: the case's explicit setting, else the CLI
    /// default, else nil (bundle default).
    public static func resolve(_ caseValue: Bool?) -> Bool? {
        caseValue ?? requested
    }

    /// Human/report label: `on`, `off`, or nil when nothing was requested.
    public static var label: String? {
        requested.map { $0 ? "on" : "off" }
    }
}
