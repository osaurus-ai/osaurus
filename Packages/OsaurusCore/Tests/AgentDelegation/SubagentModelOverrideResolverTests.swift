//
//  SubagentModelOverrideResolverTests.swift
//  OsaurusCoreTests — Agent delegation
//
//  Pins the single resolver every chat-driven kind reads for its per-run model
//  override: `SubagentToolVisibility.effectiveSubagentModel`. The Default / main
//  chat reads the global override map; a custom agent reads its own; a blank or
//  absent value resolves to `nil` (inherit the kind's default model source).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Subagent model override resolver")
struct SubagentModelOverrideResolverTests {

    @Test("a custom agent reads its own per-agent override map")
    func customAgentReadsSettings() {
        var settings = AgentSettings.defaultDisabled
        settings.subagentModelOverrides = ["computer_use": "vision-model"]

        let model = SubagentToolVisibility.effectiveSubagentModel(
            capabilityId: "computer_use",
            isDefault: false,
            config: .default,
            settings: settings
        )
        #expect(model == "vision-model")
    }

    @Test("the main chat reads the global override map")
    func mainChatReadsGlobalConfig() {
        let config = SubagentConfiguration(subagentModelOverrides: ["spawn": "global-model"])

        let model = SubagentToolVisibility.effectiveSubagentModel(
            capabilityId: "spawn",
            isDefault: true,
            config: config,
            settings: nil
        )
        #expect(model == "global-model")
    }

    @Test("an absent or blank override resolves to nil (inherit)")
    func absentOrBlankIsNil() {
        // Absent entirely.
        #expect(
            SubagentToolVisibility.effectiveSubagentModel(
                capabilityId: "computer_use",
                isDefault: false,
                config: .default,
                settings: AgentSettings.defaultDisabled
            ) == nil
        )

        // Blank value — `AgentSettings` does not normalize its map, so the
        // resolver must trim and treat whitespace as "inherit".
        var settings = AgentSettings.defaultDisabled
        settings.subagentModelOverrides = ["computer_use": "   "]
        #expect(
            SubagentToolVisibility.effectiveSubagentModel(
                capabilityId: "computer_use",
                isDefault: false,
                config: .default,
                settings: settings
            ) == nil
        )
    }

    @Test("custom and main-chat override maps are isolated")
    func customAndDefaultAreIsolated() {
        let config = SubagentConfiguration(subagentModelOverrides: ["spawn": "global-only"])
        var settings = AgentSettings.defaultDisabled
        settings.subagentModelOverrides = ["spawn": "agent-only"]

        // A custom agent ignores the global map.
        #expect(
            SubagentToolVisibility.effectiveSubagentModel(
                capabilityId: "spawn",
                isDefault: false,
                config: config,
                settings: settings
            ) == "agent-only"
        )
        // The Default agent ignores per-agent settings.
        #expect(
            SubagentToolVisibility.effectiveSubagentModel(
                capabilityId: "spawn",
                isDefault: true,
                config: config,
                settings: settings
            ) == "global-only"
        )
    }

    @Test("a nil settings (no agent context) resolves to nil for a custom lookup")
    func nilSettingsIsNil() {
        #expect(
            SubagentToolVisibility.effectiveSubagentModel(
                capabilityId: "computer_use",
                isDefault: false,
                config: .default,
                settings: nil
            ) == nil
        )
    }

    @Test("Computer Use: agent override, then Model Defaults, then inherit")
    func computerUseFallsBackToModelDefault() {
        let config = SubagentConfiguration(subagentModelOverrides: ["computer_use": "global-cu"])
        var own = AgentSettings.defaultDisabled
        own.subagentModelOverrides = ["computer_use": "agent-cu"]
        var blank = AgentSettings.defaultDisabled
        blank.subagentModelOverrides = ["computer_use": "  "]

        func resolve(_ settings: AgentSettings?, _ config: SubagentConfiguration) -> String? {
            SubagentToolVisibility.effectiveSubagentModel(
                capabilityId: "computer_use", isDefault: false, config: config, settings: settings
            )
        }
        #expect(resolve(own, config) == "agent-cu")
        #expect(resolve(AgentSettings.defaultDisabled, config) == "global-cu")
        #expect(resolve(blank, config) == "global-cu")
        #expect(resolve(nil, config) == "global-cu")
        #expect(resolve(AgentSettings.defaultDisabled, .default) == nil)
    }

    @Test("only kinds with a Model Defaults row fall back to the global map")
    func globalFallbackIsPerKind() {
        #expect(SubagentCapabilityRegistry.computerUse.hasGlobalModelDefault)
        #expect(!SubagentCapabilityRegistry.spawn.hasGlobalModelDefault)
        #expect(!SubagentCapabilityRegistry.browserUse.hasGlobalModelDefault)
        let config = SubagentConfiguration(subagentModelOverrides: [
            "spawn": "main-chat-spawn", "browser_use": "global-browser",
        ])
        for kind in ["spawn", "browser_use"] {
            #expect(
                SubagentToolVisibility.effectiveSubagentModel(
                    capabilityId: kind, isDefault: false, config: config,
                    settings: AgentSettings.defaultDisabled
                ) == nil
            )
        }
    }
}
