//
//  PluginCreatorGate.swift
//  osaurus
//
//  Pure decision logic + formatting for the plugin-creator backstop.
//

import Foundation

/// Pure decision logic + formatting for the plugin-creator backstop — the
/// `## Building new tools` section that teaches the plugin format whenever
/// plugin creation is enabled.
///
/// Extracted from `SystemPromptComposer` so the gate can be unit-tested
/// without fighting `ToolRegistry.shared` / `AgentManager.shared`. The
/// composer snapshots all inputs at the start of a turn, then calls
/// `shouldInject(_:)` with plain booleans — no actor hops, no globals.
public enum PluginCreatorGate {
    /// Every input that decides whether to inject the section this turn.
    /// Agent-side flags ride on the composer's `AgentConfigSnapshot`,
    /// captured once at the start of compose so the gate sees the same
    /// view of the world the rest of the pipeline does.
    public struct Inputs: Equatable, Sendable {
        public var effectiveToolsOff: Bool
        public var sandboxAvailable: Bool
        public var canCreatePlugins: Bool

        public init(
            effectiveToolsOff: Bool,
            sandboxAvailable: Bool,
            canCreatePlugins: Bool
        ) {
            self.effectiveToolsOff = effectiveToolsOff
            self.sandboxAvailable = sandboxAvailable
            self.canCreatePlugins = canCreatePlugins
        }
    }

    /// Pure gate. Returns true iff every condition holds:
    /// - tools aren't globally off
    /// - sandbox is available (either already active or autonomous-enabled)
    /// - the agent is allowed to create plugins (the `pluginCreate` flag, which
    ///   is also the single user-facing control for plugin creation)
    ///
    /// `sandbox_plugin_register` is always-loaded whenever plugin creation is
    /// enabled, but it lives in the base schema with no tool group beneath it,
    /// so nothing ever pulls in the teaching section the way loading a governing
    /// skill pulls its tool group. This gate is that inverse link: when plugin
    /// creation is enabled, inject the section that explains the plugin format
    /// so the register action never arrives without its instructions.
    public static func shouldInject(_ inputs: Inputs) -> Bool {
        !inputs.effectiveToolsOff
            && inputs.sandboxAvailable
            && inputs.canCreatePlugins
    }

    /// Pure formatter for the injected section. `instructions` nests its own
    /// `###` subsections under this single `## Building new tools` heading, so
    /// the section reads as one block. Callers pass
    /// `SystemPromptTemplates.pluginCreatorInstructions`.
    public static func section(instructions: String) -> String {
        """
        ## Building new tools

        Plugin creation is enabled for this session: you can build sandbox
        plugins that add new tools you can call immediately and that persist
        for later sessions. The recipe below shows how.

        \(instructions)
        """
    }
}
