//
//  SubagentCapabilityRegistry.swift
//  OsaurusCore — Subagent framework
//
//  One per-agent capability registry for the nested sub-agent family. Each
//  capability declares its gate, the tool name(s) it gates, and the
//  system-prompt guidance to inject when the capability is live. Both the
//  native `SystemPromptComposer` and the HTTP `enrichWithAgentContext` path
//  consume `SubagentToolVisibility` so the two surfaces can never drift on
//  which sub-agent tools an agent sees (the standing BUG E regression guard).
//
//  Replaces the parallel hand-written `computerUseEnabled` / `spawnDelegationEnabled`
//  gate blocks + guidance sections in the composer and the hardcoded
//  `["image_generate","image_edit","local_delegate","spawn"]` list in the HTTP
//  path.
//

import Foundation

/// Static descriptor for one gated sub-agent capability.
public struct SubagentCapability: Sendable {
    /// How this capability is gated per agent.
    public enum Gate: Sendable {
        /// Authoritative per-agent flag, stripped in BOTH auto + manual mode
        /// (computer_use). The Default agent never enables it.
        case computerUse
        /// The spawn/image delegation family: the Default agent surfaces it
        /// when the GLOBAL delegation switch is on; a custom agent surfaces it
        /// when its per-agent `spawnDelegationEnabled` is on.
        case delegation
    }

    /// Stable id (`"computer_use"`, `"spawn"`, `"image"`).
    public let id: String
    /// Tool names this capability gates. `toolNames.first` is the primary tool
    /// whose presence in the resolved schema triggers the guidance section.
    public let toolNames: [String]
    public let gate: Gate
    /// System-prompt guidance injected when the primary tool resolves.
    public let guidance: String?
    /// Stable composer section id (KV-cache identity) for the guidance block.
    public let guidanceSectionId: String?
    /// Localization key for the guidance section label.
    public let guidanceLabelKey: String?

    public var primaryToolName: String { toolNames.first ?? id }

    public init(
        id: String,
        toolNames: [String],
        gate: Gate,
        guidance: String? = nil,
        guidanceSectionId: String? = nil,
        guidanceLabelKey: String? = nil
    ) {
        self.id = id
        self.toolNames = toolNames
        self.gate = gate
        self.guidance = guidance
        self.guidanceSectionId = guidanceSectionId
        self.guidanceLabelKey = guidanceLabelKey
    }
}

/// The registry of sub-agent capabilities, in a stable order (so the guidance
/// sections render in a KV-cache-stable sequence).
public enum SubagentCapabilityRegistry {
    public static let computerUse = SubagentCapability(
        id: "computer_use",
        toolNames: [ComputerUseTool.toolName],
        gate: .computerUse,
        guidance: SystemPromptTemplates.computerUseGuidance,
        guidanceSectionId: "computerUse",
        guidanceLabelKey: "Computer Use"
    )

    /// The text-spawn family — just `spawn` now that `local_delegate` is gone.
    /// No guidance section today. Names are declared here as the SSOT (the
    /// registry is authoritative for sub-agent tool visibility); `ToolRegistry`'s
    /// parallel sets mirror these for its internal gating.
    public static let spawn = SubagentCapability(
        id: "spawn",
        toolNames: ["spawn"],
        gate: .delegation
    )

    /// The image family — one `image` tool that both generates and edits
    /// (`source_paths` → edit). The guidance renders when `image` resolves.
    public static let image = SubagentCapability(
        id: "image",
        toolNames: ["image"],
        gate: .delegation,
        guidance: SystemPromptTemplates.imageGenerationGuidance,
        guidanceSectionId: "imageGeneration",
        guidanceLabelKey: "Image Generation"
    )

    /// Every capability, in guidance-render order (computer_use, then image;
    /// spawn has no guidance and is skipped at render time).
    public static let all: [SubagentCapability] = [computerUse, spawn, image]

    /// The delegation-gated capabilities (spawn + image).
    public static let delegationFamily: [SubagentCapability] = [spawn, image]
}

/// Shared sub-agent tool-visibility resolver used by BOTH the native
/// `SystemPromptComposer.resolveTools` and the HTTP `enrichWithAgentContext`
/// path, so the two surfaces always agree on which sub-agent tools an agent
/// sees. This is the single point that previously diverged (BUG E).
public enum SubagentToolVisibility {
    /// SSOT for the delegation-family tool names both surfaces gate together.
    public static var delegationToolNames: Set<String> {
        var names = Set<String>()
        for cap in SubagentCapabilityRegistry.delegationFamily {
            names.formUnion(cap.toolNames)
        }
        return names
    }

    /// Whether the delegation family is visible for this agent. The Default
    /// agent is governed by the GLOBAL delegation switch; a custom agent by its
    /// own `spawnDelegationEnabled` flag.
    public static func delegationEnabled(
        agentId: UUID,
        perAgentEnabled: Bool,
        globalEnabled: Bool
    ) -> Bool {
        agentId == Agent.defaultId ? globalEnabled : perAgentEnabled
    }
}
