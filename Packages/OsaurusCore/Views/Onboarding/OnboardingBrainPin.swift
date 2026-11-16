//
//  OnboardingBrainPin.swift
//  osaurus
//
//  Pins agents' default model to the brain chosen on the Configure AI
//  screen: in the onboarding window at finish, and in the chat's Choose a
//  Brain sheet. While the Osaurus Cloud pin waits for the Router's catalog
//  (and after it gives up) the first-run chat reads `cloudPending` and says
//  Cloud is still connecting instead of saying nothing.
//

import Foundation

@MainActor
enum OnboardingBrainPin {
    /// Osaurus Cloud was chosen and no Cloud model has been pinned yet.
    private(set) static var cloudPending = false

    /// Pin the given agents' default model to the brain source the user
    /// committed to (Osaurus Cloud, local, a provider key, or Claude Code).
    /// Selecting local or a provider never routes through the hosted router
    /// implicitly; only the explicit `.osaurus` choice pins a router model.
    static func pin(_ state: ConfigureAIState, forAgents targets: [UUID]) {
        switch state.selectedBrainSource {
        case .osaurus:
            // (Re-)enable the managed router: a no-op unless a previous
            // opt-out is being overridden by this explicit choice.
            RemoteProviderManager.shared.setOsaurusRouterEnabled(true)
            pinOsaurusRouterModel(forAgents: targets)
        case .local:
            // The model may still be downloading; the id is durable and
            // `ChatView.refreshPickerItems` re-resolves it once the bundle lands.
            if let localModelId = state.localDefaultModelIdToPin {
                for agentId in targets {
                    AgentManager.shared.updateDefaultModel(for: agentId, model: localModelId)
                }
            }
        case .providerKey:
            // The provider auto-connects, but its catalog populates async; poll
            // (bounded) for its first chat-capable model, then pin it.
            if let providerId = state.providerModelPinTarget {
                Task { @MainActor in
                    await pinModelWhenAvailable(forAgents: targets, attempts: 20) {
                        RemoteProviderManager.shared.firstChatCapableModelId(forProviderId: providerId)
                    }
                }
            }
        case .claudeCode:
            // Claude Code is a harness runtime, not a model: the agents run
            // their chats in it, and their own model setting stays untouched.
            let runtime = HarnessRuntimeStore.shared.ensureClaudeCodeRuntime()
            for agentId in targets {
                var claude = AgentManager.shared.effectiveClaudeCodeConfig(for: agentId)
                claude.model = ClaudeCodeModel.sonnet.rawValue
                AgentManager.shared.updateClaudeCodeConfig(claude, for: agentId)
                AgentManager.shared.updateRuntime(.harness(runtime.id), for: agentId)
            }
        case nil:
            break
        }
    }

    /// Poll (bounded, ~20s) for the router's first-run model and pin it. The
    /// identity setup may still be in flight, so each poll retries the
    /// single-shot connect (a cheap no-op once connected or while
    /// connecting) before looking the model up. After the last poll
    /// `cloudPending` stays set, so the chat keeps offering Choose a Brain.
    private static func pinOsaurusRouterModel(forAgents agentIds: [UUID]) {
        cloudPending = true
        Task { @MainActor in
            for _ in 0 ..< 40 {
                if let model = RemoteProviderManager.shared.firstRunOsaurusRouterModelId() {
                    for agentId in agentIds {
                        AgentManager.shared.updateDefaultModel(for: agentId, model: model)
                    }
                    cloudPending = false
                    return
                }
                await RemoteProviderManager.shared.connectOsaurusRouterIfPossible()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Poll (bounded) for a model id via `lookup`, pinning it as every
    /// `agentIds` default the moment one resolves. Polls every 500ms up to
    /// `attempts` times, then gives up quietly so it never hangs (the user
    /// can still pick in chat).
    private static func pinModelWhenAvailable(
        forAgents agentIds: [UUID],
        attempts: Int,
        lookup: () -> String?
    ) async {
        for _ in 0 ..< attempts {
            if let model = lookup() {
                for agentId in agentIds {
                    AgentManager.shared.updateDefaultModel(for: agentId, model: model)
                }
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
