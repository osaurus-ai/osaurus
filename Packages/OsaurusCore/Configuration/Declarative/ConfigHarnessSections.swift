//
//  ConfigHarnessSections.swift
//  osaurus
//
//  Declarative shapes for harness runtimes (`harness_runtimes`) and an
//  agent's runtime choice (`runtime` + `claude_code` on `agents[]` and
//  `default_agent`).
//

import Foundation

/// A registered harness runtime. Matched by `name` (case-insensitive).
/// Creating one, or changing its command line or environment, is HIGH RISK:
/// every chat of an agent on it launches that local program.
public struct HarnessRuntimeEntry: Codable, Equatable, Sendable {
    public var name: String
    /// `claude_code` | `pi_rpc`. Required to create; immutable after.
    public var kind: String?
    /// Command name on the login-shell PATH, or a path (`~` expands).
    public var executable: String?
    /// Replaces the list. `{chat_id}`, `{agent_id}`, `{cwd}` and
    /// `{system_prompt_file}` are substituted per launch.
    public var arguments: [String]?
    /// Plain values only; merged into the runtime's environment.
    public var environment: [String: String]?

    public init(name: String) {
        self.name = name
    }
}

/// Claude Code options for an agent whose runtime is a Claude Code harness.
/// Only provided keys change.
public struct AgentClaudeCodeEntry: Codable, Equatable, Sendable {
    /// `--model`: `sonnet`, `opus`, `fable`, `haiku`, or a full model id.
    public var model: String?
    /// `--effort`: `low` … `max`, or `default` for the CLI's own default.
    public var effort: String?
    /// `agent` | `text_only`.
    public var mode: String?
    public var allowWrites: Bool?
    public var allowShell: Bool?
    public var allowOsaurusTools: Bool?
    /// Default agent only: the Osaurus config tools are the Orchestrator's.
    public var allowOsaurusConfigWrites: Bool?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case model, effort, mode
        case allowWrites = "allow_writes"
        case allowShell = "allow_shell"
        case allowOsaurusTools = "allow_osaurus_tools"
        case allowOsaurusConfigWrites = "allow_osaurus_config_writes"
    }
}

enum ConfigHarness {
    /// `runtime:` value for Osaurus's own loop. Reserved as a runtime name.
    static let builtInRuntimeKey = "builtin"

    static let kindKeys = ["claude_code", "pi_rpc"]
    static let modeKeys = ["agent", "text_only"]
    /// `claude_code.effort` value that clears the override.
    static let defaultEffortKey = "default"
    static let effortKeys = [defaultEffortKey] + ClaudeCodeEffort.allCases.map(\.rawValue)

    /// `.some(nil)` clears the override; nil is an unknown value.
    static func effort(forKey raw: String) -> ClaudeCodeEffort?? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty || key == defaultEffortKey { return .some(nil) }
        return ClaudeCodeEffort(rawValue: key).map { .some($0) }
    }

    static func kind(forKey raw: String) -> HarnessKind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude_code": return .claudeCode
        case "pi_rpc": return .piRPC
        default: return nil
        }
    }

    static func key(for kind: HarnessKind) -> String {
        switch kind {
        case .claudeCode: return "claude_code"
        case .piRPC: return "pi_rpc"
        }
    }

    static func mode(forKey raw: String) -> ClaudeCodeMode? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "agent": return .agent
        case "text_only": return .textOnly
        default: return nil
        }
    }

    static func key(for mode: ClaudeCodeMode) -> String {
        switch mode {
        case .agent: return "agent"
        case .textOnly: return "text_only"
        }
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @MainActor
    static func runtime(named name: String) -> HarnessRuntime? {
        let key = normalizedName(name)
        return HarnessRuntimeStore.shared.all().first { normalizedName($0.displayName) == key }
    }

    /// `runtime:` value for an agent. Nil for a runtime that was deleted, so
    /// an export re-applies without moving the agent anywhere.
    @MainActor
    static func runtimeKey(for runtime: AgentRuntime?) -> String? {
        guard let id = runtime?.harnessId else { return builtInRuntimeKey }
        return HarnessRuntimeStore.shared.runtime(id: id)?.displayName
    }

    /// The runtime a `runtime:` value names, or nil when no runtime by that
    /// name is registered.
    @MainActor
    static func resolve(_ key: String) -> AgentRuntime? {
        if normalizedName(key) == builtInRuntimeKey { return .builtIn }
        return runtime(named: key).map { .harness($0.id) }
    }

    /// Runtime names that exist once the document is applied: the current
    /// ones plus those it creates, or only the document's own when it prunes
    /// `harness_runtimes`.
    @MainActor
    static func effectiveRuntimeNames(document: OsaurusConfigDocument, prune: Bool) -> Set<String> {
        let declared = Set((document.harnessRuntimes ?? []).map { normalizedName($0.name) })
        if prune, document.harnessRuntimes != nil { return declared }
        return declared.union(HarnessRuntimeStore.shared.all().map { normalizedName($0.displayName) })
    }

    static func export(_ config: ClaudeCodeAgentConfig, includeConfigWrites: Bool) -> AgentClaudeCodeEntry {
        var entry = AgentClaudeCodeEntry()
        entry.model = config.resolvedModel
        entry.effort = config.resolvedEffort?.rawValue ?? defaultEffortKey
        entry.mode = key(for: config.mode)
        entry.allowWrites = config.allowWrites
        entry.allowShell = config.allowShell
        entry.allowOsaurusTools = config.allowOsaurusTools
        if includeConfigWrites { entry.allowOsaurusConfigWrites = config.allowOsaurusConfigWrites }
        return entry
    }

    static func patch(_ config: inout ClaudeCodeAgentConfig, from entry: AgentClaudeCodeEntry) {
        if let model = entry.model {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            config.model = trimmed.isEmpty ? nil : trimmed
        }
        if let raw = entry.effort, let effort = effort(forKey: raw) { config.effort = effort?.rawValue }
        if let raw = entry.mode, let mode = mode(forKey: raw) { config.mode = mode }
        if let v = entry.allowWrites { config.allowWrites = v }
        if let v = entry.allowShell { config.allowShell = v }
        if let v = entry.allowOsaurusTools { config.allowOsaurusTools = v }
        if let v = entry.allowOsaurusConfigWrites { config.allowOsaurusConfigWrites = v }
    }

    /// Plan lines for a `claude_code` block against the stored options.
    static func changes(
        _ entry: AgentClaudeCodeEntry, current: ClaudeCodeAgentConfig, prefix: String
    ) -> [String] {
        var desired = current
        patch(&desired, from: entry)
        var out: [String] = []
        if desired.resolvedModel != current.resolvedModel {
            out.append("\(prefix).model: \(current.resolvedModel) -> \(desired.resolvedModel)")
        }
        if desired.resolvedEffort != current.resolvedEffort {
            let old = current.resolvedEffort?.rawValue ?? defaultEffortKey
            let new = desired.resolvedEffort?.rawValue ?? defaultEffortKey
            out.append("\(prefix).effort: \(old) -> \(new)")
        }
        if desired.mode != current.mode {
            out.append("\(prefix).mode: \(key(for: current.mode)) -> \(key(for: desired.mode))")
        }
        func flag(_ name: String, _ old: Bool, _ new: Bool) {
            if old != new { out.append("\(prefix).\(name): \(old) -> \(new)") }
        }
        flag("allow_writes", current.allowWrites, desired.allowWrites)
        flag("allow_shell", current.allowShell, desired.allowShell)
        flag("allow_osaurus_tools", current.allowOsaurusTools, desired.allowOsaurusTools)
        flag(
            "allow_osaurus_config_writes", current.allowOsaurusConfigWrites,
            desired.allowOsaurusConfigWrites)
        return out
    }

    /// Risk lines for switches a `claude_code` block newly turns on.
    static func risks(
        _ entry: AgentClaudeCodeEntry, current: ClaudeCodeAgentConfig, agent: String
    ) -> [String] {
        var out: [String] = []
        if entry.allowShell == true, !current.allowShell {
            out.append(ConfigRisk.claudeCodeShell(agent))
        }
        if entry.allowOsaurusConfigWrites == true, !current.allowOsaurusConfigWrites {
            out.append(ConfigRisk.claudeCodeConfigWrites(agent))
        }
        return out
    }
}
