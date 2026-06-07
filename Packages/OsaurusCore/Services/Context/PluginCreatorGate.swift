//
//  PluginCreatorGate.swift
//  osaurus
//
//  Pure decision logic + formatting for the "Sandbox Plugin Creator" backstop.
//

import Foundation

/// Pure decision logic + formatting for the "Sandbox Plugin Creator" backstop.
///
/// Extracted from `SystemPromptComposer` so the gate can be unit-tested
/// without fighting `ToolRegistry.shared` / `SkillManager.shared` / `AgentManager.shared`.
/// The composer snapshots all inputs at the start of a turn, then calls
/// `shouldInject(_:)` with plain booleans — no actor hops, no globals.
public enum PluginCreatorGate {
    /// Every input that decides whether to inject the skill this turn.
    /// Agent-side flags ride on the composer's `AgentConfigSnapshot`,
    /// captured once at the start of compose so the gate sees the same
    /// view of the world the rest of the pipeline does.
    public struct Inputs: Equatable, Sendable {
        public var effectiveToolsOff: Bool
        public var sandboxAvailable: Bool
        public var canCreatePlugins: Bool
        public var dynamicCatalogIsEmpty: Bool
        public var hasResolvedDynamicTools: Bool
        public var skillEnabled: Bool

        public init(
            effectiveToolsOff: Bool,
            sandboxAvailable: Bool,
            canCreatePlugins: Bool,
            dynamicCatalogIsEmpty: Bool,
            hasResolvedDynamicTools: Bool,
            skillEnabled: Bool
        ) {
            self.effectiveToolsOff = effectiveToolsOff
            self.sandboxAvailable = sandboxAvailable
            self.canCreatePlugins = canCreatePlugins
            self.dynamicCatalogIsEmpty = dynamicCatalogIsEmpty
            self.hasResolvedDynamicTools = hasResolvedDynamicTools
            self.skillEnabled = skillEnabled
        }
    }

    /// Pure gate. Returns true iff every condition holds:
    /// - tools aren't globally off
    /// - sandbox is available (either already active or autonomous-enabled)
    /// - the agent is allowed to create plugins
    /// - the user has no dynamic tools installed AND this turn didn't resolve any
    /// - the user hasn't disabled the built-in skill
    public static func shouldInject(_ inputs: Inputs) -> Bool {
        !inputs.effectiveToolsOff
            && inputs.sandboxAvailable
            && inputs.canCreatePlugins
            && inputs.dynamicCatalogIsEmpty
            && !inputs.hasResolvedDynamicTools
            && inputs.skillEnabled
    }

    /// Pure formatter for the injected section.
    public static func section(skillName: String, instructions: String) -> String {
        """
        ## No existing tools match this request

        You can create new tools by writing a sandbox plugin.
        Follow the instructions below.

        ## Skill: \(skillName)
        \(instructions)
        """
    }
}
