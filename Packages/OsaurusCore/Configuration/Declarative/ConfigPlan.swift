//
//  ConfigPlan.swift
//  osaurus
//
//  The diff between a declarative document and current Osaurus state.
//  A plan is advisory: `apply` recomputes state at execution time and
//  sets each declared section to match the document (idempotent merge),
//  so the plan's job is to tell the user/agent exactly what will change
//  and to carry the high-risk flags that gate apply approval.
//

import Foundation

/// One planned change against a single target.
public struct ConfigPlanAction: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case create
        case update
        case delete
        /// The change needs an interactive step during apply (e.g. a
        /// credential sheet for a new cloud provider).
        case needsUserInput = "needs_user_input"
    }

    /// Section this action belongs to (`server`, `agents`, ...).
    public var section: String
    /// Human identifier of the target ("server", agent name, repo id, ...).
    public var target: String
    public var kind: Kind
    /// Field-level change lines, e.g. `port: 1337 -> 8080`. Values are
    /// truncated for display; secrets never appear (the schema has none).
    public var changes: [String]
    /// High-risk markers. A non-empty list forces an explicit user
    /// approval during apply, even under always-allow.
    public var risks: [String]
    /// True when the change keeps running after apply returns (model
    /// downloads) and should be polled via `osaurus_inspect` ({action: 'status'}).
    public var longRunning: Bool

    public init(
        section: String,
        target: String,
        kind: Kind,
        changes: [String] = [],
        risks: [String] = [],
        longRunning: Bool = false
    ) {
        self.section = section
        self.target = target
        self.kind = kind
        self.changes = changes
        self.risks = risks
        self.longRunning = longRunning
    }
}

/// Full plan for one document against current state.
public struct ConfigPlan: Equatable, Sendable {
    public var actions: [ConfigPlanAction]
    /// Non-fatal notes (e.g. "3 agents already match — no change").
    public var notes: [String]

    public init(actions: [ConfigPlanAction] = [], notes: [String] = []) {
        self.actions = actions
        self.notes = notes
    }

    public var isEmpty: Bool { actions.isEmpty }

    /// Every distinct risk across all actions.
    public var risks: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for action in actions {
            for risk in action.risks where !seen.contains(risk) {
                seen.insert(risk)
                out.append(risk)
            }
        }
        return out
    }

    public var hasHighRiskChanges: Bool { !risks.isEmpty }

    /// Compact human/model-readable rendering, grouped by section.
    public func summaryText() -> String {
        guard !actions.isEmpty else {
            var text = "No changes — current state already matches the document."
            if !notes.isEmpty { text += "\n" + notes.map { "note: \($0)" }.joined(separator: "\n") }
            return text
        }
        var lines: [String] = []
        var currentSection = ""
        for action in actions {
            if action.section != currentSection {
                currentSection = action.section
                lines.append("\(action.section):")
            }
            var head = "  \(symbol(for: action.kind)) \(action.target)"
            if action.longRunning { head += " (long-running; poll osaurus_inspect)" }
            lines.append(head)
            for change in action.changes {
                lines.append("      \(change)")
            }
            for risk in action.risks {
                lines.append("      ! \(risk)")
            }
        }
        for note in notes {
            lines.append("note: \(note)")
        }
        return lines.joined(separator: "\n")
    }

    /// Structured payload for tool envelopes / HTTP responses.
    public func payload() -> [String: Any] {
        var dict: [String: Any] = [
            "change_count": actions.count,
            "actions": actions.map { action -> [String: Any] in
                var row: [String: Any] = [
                    "section": action.section,
                    "target": action.target,
                    "kind": action.kind.rawValue,
                ]
                if !action.changes.isEmpty { row["changes"] = action.changes }
                if !action.risks.isEmpty { row["risks"] = action.risks }
                if action.longRunning { row["long_running"] = true }
                return row
            },
        ]
        if !notes.isEmpty { dict["notes"] = notes }
        if hasHighRiskChanges { dict["high_risk"] = true }
        return dict
    }

    private func symbol(for kind: ConfigPlanAction.Kind) -> String {
        switch kind {
        case .create: return "+"
        case .update: return "~"
        case .delete: return "-"
        case .needsUserInput: return "?"
        }
    }
}

/// Outcome of executing one planned action during apply.
public struct ConfigApplyResult: Equatable, Sendable {
    public enum Status: String, Sendable {
        case done
        /// Long-running work started (model download).
        case started
        case failed
        /// Registered, but the user must finish a step in Settings
        /// (e.g. paste an MCP bearer token).
        case needsUserAction = "needs_user_action"
        case cancelled
    }

    public var section: String
    public var target: String
    public var status: Status
    public var message: String?

    public init(section: String, target: String, status: Status, message: String? = nil) {
        self.section = section
        self.target = target
        self.status = status
        self.message = message
    }

    public var payload: [String: Any] {
        var row: [String: Any] = [
            "section": section,
            "target": target,
            "status": status.rawValue,
        ]
        if let message { row["message"] = message }
        return row
    }
}
