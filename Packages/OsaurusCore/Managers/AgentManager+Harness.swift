//
//  AgentManager+Harness.swift
//  osaurus
//
//  Runtime selection (built-in loop vs external harness) per agent, and the
//  one-time move of agents that ran Claude Code as a `claude-code/…` model.
//

import Foundation

extension AgentManager {
    /// Which loop runs this agent's chats.
    public func effectiveRuntime(for agentId: UUID) -> AgentRuntime {
        if agentId == Agent.defaultId {
            return DefaultAgentConfigurationStore.load().runtime ?? .builtIn
        }
        return agent(for: agentId)?.runtime ?? .builtIn
    }

    /// The harness this agent runs on, or nil for the built-in loop. A
    /// runtime id that no longer resolves (the user deleted the runtime) is
    /// reported as a missing harness rather than silently treated as
    /// built-in, so the chat can say what happened.
    public func effectiveHarness(for agentId: UUID) -> HarnessSelection? {
        guard let id = effectiveRuntime(for: agentId).harnessId else { return nil }
        if let runtime = HarnessRuntimeStore.shared.runtime(id: id) {
            return .resolved(runtime)
        }
        return .missing(id)
    }

    /// The typed refusal for surfaces that only run the built-in loop
    /// (`/agents/{id}/run`, `spawn_agent`, Computer Use, AppleScript).
    /// Running a harness agent there with built-in defaults would silently
    /// be a different agent.
    public func harnessUnsupportedError(for agentId: UUID) -> HarnessError? {
        guard effectiveHarness(for: agentId) != nil else { return nil }
        let name = agent(for: agentId)?.name ?? L("This agent")
        return .unsupportedPath(agentName: name)
    }

    public func updateRuntime(_ runtime: AgentRuntime, for agentId: UUID) {
        let stored: AgentRuntime? = runtime == .builtIn ? nil : runtime
        if agentId == Agent.defaultId {
            var config = DefaultAgentConfigurationStore.load()
            guard config.runtime != stored else { return }
            config.runtime = stored
            DefaultAgentConfigurationStore.save(config)
            NotificationCenter.default.post(name: .agentUpdated, object: agentId)
        } else {
            guard var agent = agent(for: agentId), agent.runtime != stored else { return }
            agent.runtime = stored
            update(agent)
        }
        Task { await HarnessSessionManager.shared.closeIdleSessions(agentId: agentId) }
    }

    // MARK: - Migration

    /// Agents that ran Claude Code by picking a `claude-code/<alias>` model
    /// are moved onto the Claude Code harness runtime with that alias. The
    /// model ids stop routing once the picker rows are gone, so leaving them
    /// in place would silently strand those agents on a missing model.
    ///
    /// Resolution uses the effective model (custom agents with no model of
    /// their own inherit the global/new-agent and Default-agent models), so
    /// an agent that was running Claude Code by inheritance keeps running it.
    ///
    /// Runs on every launch with no flag: every `claude-code/*` id it finds is
    /// cleared, so a second pass finds nothing, while an agent restored from
    /// an old backup still gets moved.
    func migrateClaudeCodeModelsToHarness() {
        var defaultConfig = DefaultAgentConfigurationStore.load()
        var chatConfig = ChatConfigurationStore.load()
        let inheritedDefault = defaultConfig.defaultModel
        let inheritedGlobal = chatConfig.defaultModel

        func alias(_ model: String?) -> String? {
            guard let model else { return nil }
            return ClaudeCodeModel.fromPickerId(model)?.rawValue
                ?? (model.hasPrefix(ClaudeCodeConfiguration.modelPrefix)
                    ? String(model.dropFirst(ClaudeCodeConfiguration.modelPrefix.count)) : nil)
        }

        let customAgents = agents.filter { !$0.isBuiltIn }
        let needsMigration =
            alias(inheritedDefault) != nil || alias(inheritedGlobal) != nil
            || customAgents.contains { alias($0.defaultModel) != nil }
        guard needsMigration else { return }

        // Only resolved (and seeded, if the user never had it) when an agent
        // actually moves onto it.
        var claudeRuntimeId: UUID?
        func claudeRuntime() -> UUID {
            if let claudeRuntimeId { return claudeRuntimeId }
            let id = HarnessRuntimeStore.shared.ensureClaudeCodeRuntime().id
            claudeRuntimeId = id
            return id
        }

        for var agent in customAgents {
            let ownModelIsDead = alias(agent.defaultModel) != nil
            let effective = agent.defaultModel ?? inheritedGlobal ?? inheritedDefault
            guard let modelAlias = alias(effective) else { continue }
            if agent.runtime == nil {
                var claude = agent.claudeCode ?? .default
                claude.model = modelAlias
                agent.claudeCode = claude
                agent.runtime = .harness(claudeRuntime())
            } else if !ownModelIsDead {
                continue
            }
            if ownModelIsDead { agent.defaultModel = nil }
            update(agent)
        }

        if let modelAlias = alias(inheritedDefault) {
            if defaultConfig.runtime == nil {
                var claude = defaultConfig.claudeCode ?? .default
                claude.model = modelAlias
                defaultConfig.claudeCode = claude
                defaultConfig.runtime = .harness(claudeRuntime())
            }
            defaultConfig.defaultModel = nil
            DefaultAgentConfigurationStore.save(defaultConfig)
            NotificationCenter.default.post(name: .agentUpdated, object: Agent.defaultId)
        }

        if alias(inheritedGlobal) != nil {
            chatConfig.defaultModel = nil
            ChatConfigurationStore.save(chatConfig)
        }
    }
}

public enum HarnessSelection: Sendable, Equatable {
    case resolved(HarnessRuntime)
    /// The agent names a runtime that no longer exists.
    case missing(UUID)
}
