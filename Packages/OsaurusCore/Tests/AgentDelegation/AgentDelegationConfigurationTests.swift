//
//  AgentDelegationConfigurationTests.swift
//  osaurusTests
//
//  Covers the persisted settings contract used by cloud-to-local text
//  delegation and agent-triggered native image jobs.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent delegation configuration")
struct AgentDelegationConfigurationTests {
    @Test("defaults are low RAM and ask-first")
    func defaultsAreSafe() {
        let config = AgentDelegationConfiguration.default
        #expect(config.cloudTextDelegationEnabled == false)
        #expect(config.textDelegateLoadPolicy == .unloadAfterJob)
        #expect(config.imageJobLoadPolicy == .agentSingleResidency)
        #expect(config.permissionDefaults.localTextDelegate == .ask)
        #expect(config.permissionDefaults.localTextDelegateToolUse == .ask)
        #expect(config.permissionDefaults.imageGenerate == .ask)
        #expect(config.permissionDefaults.imageEdit == .ask)
        #expect(config.budgets.maxDelegateTokens == 2048)
        #expect(config.budgets.maxDelegateTurns == 1)
        #expect(config.budgets.maxToolCalls == 0)
        #expect(config.budgets.maxElapsedSeconds == 120)
    }

    @Test("budget normalization clamps invalid values")
    func budgetNormalizationClampsInvalidValues() {
        let raw = AgentDelegationBudgets(
            maxDelegateTokens: -10,
            maxDelegateTurns: 0,
            maxToolCalls: -1,
            maxElapsedSeconds: 0
        )

        #expect(raw.normalized.maxDelegateTokens == 256)
        #expect(raw.normalized.maxDelegateTurns == 1)
        #expect(raw.normalized.maxToolCalls == 0)
        #expect(raw.normalized.maxElapsedSeconds == 15)
    }

    @Test("budget normalization caps runaway values")
    func budgetNormalizationCapsRunawayValues() {
        let raw = AgentDelegationBudgets(
            maxDelegateTokens: 1_000_000,
            maxDelegateTurns: 100,
            maxToolCalls: 100,
            maxElapsedSeconds: 100_000
        )

        #expect(raw.normalized.maxDelegateTokens == 32_768)
        #expect(raw.normalized.maxDelegateTurns == 8)
        #expect(raw.normalized.maxToolCalls == 32)
        #expect(raw.normalized.maxElapsedSeconds == 1_800)
    }

    @Test("configuration round trips stable raw values")
    func configurationRoundTrip() throws {
        let config = AgentDelegationConfiguration(
            cloudTextDelegationEnabled: true,
            defaultLocalTextDelegateModelId: "local-chat",
            defaultImageGenerationModelId: "flux-schnell",
            defaultImageEditModelId: "qwen-image-edit",
            textDelegateLoadPolicy: .keepWarmWhenSafe,
            imageJobLoadPolicy: .manualPanelKeepsImageLoaded,
            sharingPolicy: .askBeforeExpandedSharing,
            permissionDefaults: AgentDelegationPermissionDefaults(
                localTextDelegate: .alwaysAllow,
                localTextDelegateToolUse: .deny,
                imageGenerate: .ask,
                imageEdit: .alwaysAllow
            ),
            budgets: AgentDelegationBudgets(
                maxDelegateTokens: 4096,
                maxDelegateTurns: 2,
                maxToolCalls: 3,
                maxElapsedSeconds: 240
            )
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AgentDelegationConfiguration.self, from: data)

        #expect(decoded == config)
        #expect(decoded.permissionDefaults.localTextDelegate.rawValue == "always_allow")
        #expect(decoded.textDelegateLoadPolicy.rawValue == "keep_warm_when_safe")
        #expect(decoded.imageJobLoadPolicy.rawValue == "manual_panel_keeps_image_loaded")
    }

    @Test("normalization preserves a disabled RAM-safety preflight")
    func normalizationPreservesRamSafetyChoice() {
        // Regression: `.normalized` previously omitted ramSafetyPreflightEnabled, so
        // turning it OFF was silently reverted to the init default (true) on every
        // save/load (the store runs `.normalized` on both). It must survive.
        var config = AgentDelegationConfiguration(agentDelegationEnabled: true)
        config.ramSafetyPreflightEnabled = false

        #expect(config.normalized.ramSafetyPreflightEnabled == false)

        // Through a full encode round-trip too (decode then normalize).
        let data = try! JSONEncoder().encode(config)
        let decoded = try! JSONDecoder().decode(AgentDelegationConfiguration.self, from: data)
        #expect(decoded.ramSafetyPreflightEnabled == false)
        #expect(decoded.normalized.ramSafetyPreflightEnabled == false)
    }

    @Test("normalization preserves spawnable agent names")
    func normalizationPreservesSpawnableNames() {
        var config = AgentDelegationConfiguration(agentDelegationEnabled: true)
        config.spawnableAgentNames = ["Researcher", "Coder"]

        #expect(config.normalized.spawnableAgentNames == ["Researcher", "Coder"])
        #expect(config.normalized.anyAgentSpawnable)
        #expect(config.normalized.isAgentSpawnable("researcher"))  // case-insensitive
    }
}
